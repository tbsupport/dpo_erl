%%% @author Vova Dem
%%%
%%% @doc
%%% @end

-module(dpo_server).
-include_lib("dpo.hrl").
-include_lib("dpo/include/rtmp.hrl").
-include_lib("dpo/include/rtmp_session.hrl").
-include_lib("erlyvideo/include/log.hrl").

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([add/3, finish/1, find/1, list/0, publish/3, config_reloaded/0]).
-export([stream_started/2, stream_stopped/1, user_disconnected/1]).
-export([get_hls_stream/2, hls_idle/1]).
-export([status/0]).

-define(DIR(Id), lists:flatten(io_lib:format("~s/~p", [ulitos_app:get_var(dpo, recording_dir, "."), Id]))).
-define(FILENAME(Id, Name), iolist_to_binary(io_lib:format("~s/~s.flv", [?DIR(Id), Name]))).

-record(state, {
  translations = #{} :: #{non_neg_integer() => #translation{}},
  sid_to_id = #{} :: #{non_neg_integer() => non_neg_integer()},
  name_to_id = #{} :: #{binary() => {non_neg_integer(), binary()}}
}).


start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  lager:info("Starting dpo_server"),
  init_http(),
  {ok, #state{}}.


%% @doc
%% Handle config was reloaded event
%% @end

-spec config_reloaded() -> any().

config_reloaded()->
  ok.

%% @doc Find translation by id.
%% @end

find(Id) ->
  gen_server:call(?MODULE,{find, Id}).

%% @doc
%%  Remove stream from registered list and disconnect
%% @end

finish(Id) ->
  gen_server:call(?MODULE, {finish, Id}).

status() ->
  ok.

list() ->
  gen_server:call(?MODULE,{list}).

publish(SessionId, Name, QS) ->
  gen_server:call(?MODULE, {publish, SessionId, Name, QS}).

%% @doc Add stream to whitelist.
%% @end

-spec add(non_neg_integer(), non_neg_integer(), pid()) -> ok|{error,any()}.

add(Id, SessionId, SessionPid) ->
  gen_server:call(?MODULE, {add, Id, SessionId, SessionPid}).

%% @doc Stream started event handler
%% @end

-spec stream_started(binary(), pid()) -> ok.

stream_started(Name, Media) ->
  gen_server:cast(?MODULE, {stream_started, Name, Media}).

%% @doc Stream stopped event handler
%% @end

-spec stream_stopped(binary()) -> ok.

stream_stopped(Name) ->
  gen_server:cast(?MODULE,{stream_stopped, Name}).

%% @doc User disconnected event handler
%% @end

-spec user_disconnected(non_neg_integer()) -> ok.

user_disconnected(SessionId) ->
  gen_server:cast(?MODULE,{user_disconnected, SessionId}).

%% @doc Get hls stream by id
%% @end

-spec get_hls_stream(non_neg_integer(), undefined | binary()) -> {ok, pid()}.

get_hls_stream(Id, undefined) ->
  gen_server:call(?MODULE, {get_hls_stream, Id});

get_hls_stream(Id, Name) ->
  gen_server:call(?MODULE, {get_hls_stream, Id, Name}).

%% @doc Notify that hls is idle
%% @end

-spec hls_idle(non_neg_integer()) -> {ok, pid()}.

hls_idle(Id) ->
  gen_server:call(?MODULE, {hls_idle, Id}).

%%%----------- gen_server handlers ------------%%%

handle_call({add, Id, SessionId, SessionPid}, _, #state{translations = Translations, sid_to_id = SidToId} = State) ->
  case maps:get(Id, Translations, undefined) of
    undefined ->
      Translation = #translation{id = Id, session_id = SessionId, session_pid = SessionPid},
      {reply, ok, State#state{translations = maps:put(Id, Translation, Translations), sid_to_id = maps:put(SessionId, Id, SidToId)}};
    #translation{session_id = undefined} = Translation ->
      {reply, ok, State#state{translations = maps:put(Id, Translation#translation{session_id = SessionId, session_pid = SessionPid}, Translations), sid_to_id = maps:put(SessionId, Id, SidToId)}};
    #translation{} ->
      {reply, {error, exist}, State}
  end;

handle_call({find, Id}, _, #state{translations = Translations} = State) ->
  {reply, maps:get(Id, Translations, undefined), State};

handle_call({finish, Id}, _, #state{translations = Translations, sid_to_id = SidToId, name_to_id = NameToId} = State) ->
  case maps:get(Id, Translations, undefined) of
    undefined ->
      {reply, ok, State};
    #translation{session_id = undefined} = Translation ->
      make_record(Translation),
      {reply, ok, State#state{translations = maps:remove(Id, Translations)}};
    #translation{session_id = Sid, session_pid = SessionPid, streams = Streams} = Translation ->
      make_record(Translation),
      (catch rtmp_session:reject_connection(SessionPid)),
      Names = maps:fold(fun(_, #dpo_stream{filename = Filename}, Acc) -> [Filename|Acc] end, [], Streams),
      NewNameToId = lists:foldl(fun maps:remove/2, NameToId, Names),
      {reply, ok, State#state{translations = maps:remove(Id, Translations), sid_to_id = maps:remove(Sid, SidToId), name_to_id = NewNameToId}}
  end;

handle_call({publish, SessionId, Name, QS}, _, #state{translations = Translations, sid_to_id = SidToId, name_to_id = NameToId} = State) ->
  Id = maps:get(SessionId, SidToId),
  #translation{streams = Streams} = Translation = maps:get(Id, Translations),
  Filename = ?FILENAME(Id, Name),
  case maps:get(Name, Streams, undefined) of
    undefined ->
      NewStreams = maps:put(Name, #dpo_stream{filename = Filename, options = QS}, Streams),
      NewNameToId = maps:put(iolist_to_binary(Filename), {Id, Name}, NameToId),
      {reply, Filename, State#state{translations = maps:put(Id, Translation#translation{streams = NewStreams}, Translations), name_to_id = NewNameToId}};
    #dpo_stream{filename = Filename} = Stream ->
      NewStreams = maps:put(Name, Stream#dpo_stream{options = QS}, Streams),
      {reply, Filename, State#state{translations = maps:put(Id, Translation#translation{streams = NewStreams}, Translations)}}
  end;

handle_call({list}, _ , #state{translations = Translations} = State) ->
  {reply, maps:values(Translations), State};

handle_call({get_hls_stream, Id}, _From, #state{translations = Translations} = State) ->
  case maps:get(Id, Translations, undefined) of
    undefined ->
      {reply, undefined, State};
    Translation ->
      {Reply, NewTranslation} = get_hls(Translation),
      {reply, Reply, State#state{translations = maps:put(Id, NewTranslation, Translations)}}
  end;

handle_call({get_hls_stream, Id, Name}, _From, #state{translations = Translations} = State) ->
  case maps:get(Id, Translations, undefined) of
    undefined ->
      {reply, undefined, State};
    #translation{streams = Streams} = Translation ->
      case maps:get(Name, Streams, undefined) of
        undefined ->
          {reply, undefined, State};
        Stream ->
          {Reply, NewStream} = get_hls(Stream),
          NewStreams = maps:put(Name, NewStream, Streams),
          NewTranslation = Translation#translation{streams = NewStreams},
          {reply, Reply, State#state{translations = maps:put(Id, NewTranslation, Translations)}}
      end
  end;

handle_call({hls_idle, _Id}, _From, #state{translations = _Translations} = State) ->
  {reply, ok, State};

handle_call(Req, _, State) ->
  {error, {unhandled, Req}, State}.

handle_cast({stream_started, Filename, Media}, #state{translations = Translations, name_to_id = NameToId} = State) ->
  case maps:get(Filename, NameToId, undefined) of
    undefined ->
      {noreply, State};
    {Id, Name} ->
      ?ACCESS("START_STREAM ~p ~p", [Id, Name]),
      Translation = #translation{streams = Streams} = maps:get(Id, Translations),
      Stream = maps:get(Name, Streams),
      NewStreams = maps:put(Name, Stream#dpo_stream{media = Media}, Streams),
      {noreply, State#state{translations = maps:put(Id, Translation#translation{streams = NewStreams}, Translations)}}
  end;

handle_cast({stream_stopped, Filename}, #state{translations = Translations, name_to_id = NameToId} = State) ->
  case maps:get(Filename, NameToId, undefined) of
    undefined ->
      {noreply, State};
    {Id, Name} ->
      ?ACCESS("STOP_STREAM ~p", [Id]),
      Translation = #translation{streams = Streams} = maps:get(Id, Translations),
      Stream  = maps:get(Name, Streams),
      NewStreams = maps:put(Name, Stream#dpo_stream{media = undefined}, Streams),
      {noreply, State#state{translations = maps:put(Id, Translation#translation{streams = NewStreams}, Translations)}}
  end;

handle_cast({user_disconnected, SessionId}, #state{translations = Translations, sid_to_id = SidToId} = State) ->
  case maps:get(SessionId, SidToId, undefined) of
    undefined ->
      {noreply, State};
    Id ->
      Translation = maps:get(Id, Translations),
      {noreply, State#state{translations = maps:put(Id, Translation#translation{session_id = undefined, session_pid = undefined}, Translations), sid_to_id = maps:remove(SessionId, SidToId)}}
  end;

handle_cast(Cast, State) ->
  {error, {unknown_cast, Cast}, State}.

handle_info(stop, State) ->
  {stop, normal, State};

handle_info(Info, State) ->
  ?D({unknown_info, Info}),
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_, State, _) -> {ok, State}.



%%% --------------- private ----------------- %%%

init_http() ->
  Routes = [
    {"/api/dpo/translations/[:id]", [{id, int}], translations_handler, []},
    {"/hls/dpo/:id/[:name]/:filename", [{id, int}], dpo_hls_handler, []}
  ],
  ems_http:add_routes(Routes).

get_hls(#dpo_stream{media = undefined, hls = undefined} = Stream) ->
  {undefined, Stream};

get_hls(#dpo_stream{media = undefined, hls = Hls} = Stream) ->
  case hls_server:get_stream(Hls) of
    undefined ->
      {undefined, Stream#dpo_stream{hls = undefined}};
    {ok, Pid} ->
      {{ok, Pid}, Stream}
  end;

get_hls(#dpo_stream{media = Media, hls = undefined} = Stream) ->
  {ok, Hls} = hls_server:add_stream(Media),
  {hls_server:get_stream(Hls), Stream#dpo_stream{hls = Hls}};

get_hls(#dpo_stream{media = Media, hls = Hls} = Stream) ->
  case hls_server:get_stream(Hls) of
    undefined ->
      {ok, NewHls} = hls_server:add_stream(Media),
      {hls_server:get_stream(NewHls), Stream#dpo_stream{hls = NewHls}};
    {ok, Pid} ->
      {{ok, Pid}, Stream}
  end;

get_hls(#translation{streams = Streams} = Translation) when map_size(Streams) == 0 ->
  {undefined, Translation};

get_hls(#translation{streams = Streams} = Translation) when map_size(Streams) == 1 ->
  [{Name, Stream}] = maps:to_list(Streams),
  {Reply, NewStream} = get_hls(Stream),
  NewTranslation = Translation#translation{streams = maps:put(Name, NewStream, Streams)},
  {Reply, NewTranslation};

get_hls(#translation{streams = Streams} = Translation) ->
  PlaylistStart = <<"#EXTM3U\n">>,
  Playlist =
    maps:fold(
      fun(Name, Stream, PL) -> StreamInf = stream_inf(Name, Stream), <<PL/binary, StreamInf/binary>> end,
      PlaylistStart,
      Streams
    ),
  {{playlist, Playlist}, Translation}.

stream_inf(Name, #dpo_stream{options = Options}) ->
  BandWidth = proplists:get_value(<<"totalDatarate">>, Options, <<"640">>),
  <<"#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=", BandWidth/binary, "000\n", Name/binary, "/playlist.m3u8\n">>.

make_record(#translation{streams = Streams}) when map_size(Streams) == 0 ->
  ok;

make_record(#translation{id = Id, streams = Streams}) ->
  MaxFun =
    fun
      (_, #dpo_stream{options = Options, filename = Filename}, {CurrentFilename, CurrentBandWidth}) ->
        BandWidth = binary_to_integer(proplists:get_value(<<"totalDatarate">>, Options, <<"0">>)),
        if
          BandWidth > CurrentBandWidth -> {Filename, BandWidth};
          true -> {CurrentFilename, CurrentBandWidth}
        end
    end,
  {Filename, _} = maps:fold(MaxFun, {<<"">>, -1}, Streams),
  file:rename(Filename, ?FILENAME(Id, <<"stream">>)),
  ?D({Filename, ?FILENAME(Id, <<"stream">>)}),
  dpo_saver:save_recording(Id, ?DIR(Id)).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(setup(F), {setup, fun setup_/0, fun cleanup_/1, F}).

-define(TPID,list_to_pid("<0.12.13>")).

setup_() ->
  meck:new(rtmp_session,[non_strict]),
  meck:expect(rtmp_session, reject_connection, fun(_X) -> dpo_server:stream_stopped(?TPID) end),
  lager:start(),
  dpo:start().

cleanup_(_) ->
  meck:unload(rtmp_session),
  application:stop(lager),
  dpo:stop().

add_stream_test_() ->
  [
    {"Add normal stream",
      ?setup(fun add_stream_t_/1)},
    {"Add stream and check params",
      ?setup(fun add_stream_params_t_/1)},
    {"Add duplicate", 
      ?setup(fun add_dup_stream_t_/1)},
    {"List streams", 
      ?setup(fun list_streams_t_/1)}
  ].

add_stream_t_(_) ->
  [
    ?_assertEqual(ok, dpo_server:add(1, 2, 3))
  ].

add_stream_params_t_(_) ->
  dpo_server:add(1, 1, 1),
  {ok,#translation{session_id = Sid, session_pid = Pid}} = dpo_server:find("test"),
  [
    ?_assertEqual(1, Sid),
    ?_assertEqual(1, Pid)
  ].

add_dup_stream_t_(_) ->
  dpo_server:add(1, 1, 1),
  [
    ?_assertEqual({error, already_exist}, dpo_server:add(1, 1, 1))
  ].

list_streams_t_(_) ->
  dpo_server:add(1, 1, 1),
  dpo_server:add(2, 2, 2),
  [
    ?_assertEqual(2, length(dpo_server:list()))
  ].

finish_stream_test_() ->
  [
    {"Finish stream",
      ?setup(fun finish_stream_t_/1)}
  ].

finish_stream_t_(_) ->
  dpo_server:add(1, 1, 1),
  [
    ?_assertEqual(ok, dpo_server:finish(1))
    ,?_assertEqual(0, length(dpo_server:list()))
  ].

live_stream_test_() ->
  [
    {"Make stream live",
      ?setup(fun add_live_stream_t_/1)},
    {"Stop live stream",
      ?setup(fun stop_live_stream_t_/1)},
    {"Close live stream",
      ?setup(fun close_live_stream_t_/1)},
    {"Finish live stream",
      ?setup(fun finish_live_stream_t_/1)}
  ].

add_live_stream_t_(_) ->
  dpo_server:add(1, 2, 3),
  Name = dpo_server:publish(2),
  dpo_server:stream_started(Name, ?TPID),
  {ok,#translation{media = Media}} = dpo_server:find(1),
  [
    ?_assertEqual(?TPID, Media)
  ].

stop_live_stream_t_(_) ->
  dpo_server:add(1, 2, 3),
  Name = dpo_server:publish(2),
  dpo_server:stream_started(Name, ?TPID),
  {ok,#translation{media = Media1}} = dpo_server:find(1),
  dpo_server:stream_stopped(Name),
  {ok,#translation{media = Media2}} = dpo_server:find(1),
  [
    ?_assertEqual(?TPID, Media1),
    ?_assertEqual(undefined, Media2)
  ].

finish_live_stream_t_(_) ->
  dpo_server:add(1, 2, 3),
  Name = dpo_server:publish(2),
  dpo_server:stream_started(Name, ?TPID),
  dpo_server:finish(1),
  [
    ?_assertEqual(undefined, dpo_server:find(1))
  ].

-endif.