%%% @author Vova Dem
%%%
%%% @doc
%%% @end

-module(dpo_server).
-include_lib("dpo.hrl").
-include_lib("../include/rtmp.hrl").
-include_lib("../include/rtmp_session.hrl").
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([add/3, finish/1, find/1, list/0, publish/1, config_reloaded/0]).
-export([stream_started/2, stream_stopped/1, user_disconnected/1]).
-export([status/0]).

-define(T_STREAMS, dpo_streams).
-define(D_TRANSLATIONS, dets_translations).

-record(state, {
  translations = #{} :: #{non_neg_integer() => #translation{}},
  sid_to_id = #{} :: #{non_neg_integer() => non_neg_integer()},
  name_to_id = #{} :: #{binary() => non_neg_integer()}
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

publish(SessionId) ->
  gen_server:call(?MODULE, {publish, SessionId}).

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


%%%----------- gen_server handlers ------------%%%

handle_call({add, Id, SessionId, SessionPid}, _, #state{translations = Translations, sid_to_id = SidToId} = State) ->
  case maps:get(Id, Translations, undefined) of
    undefined ->
      Translation = #translation{id = Id, session_id = SessionId, session_pid = SessionPid},
      {reply, ok, State#state{translations = maps:put(Id, Translation, Translations), sid_to_id = maps:put(SessionId, Id, SidToId)}};
    #translation{session_id = undefined} = Translation ->
      {reply, ok, State#state{translations = maps:put(Id, Translation#translation{session_id = SessionId, session_pid = SessionPid}, Translations), sid_to_id = maps:put(SessionId, Id, SidToId)}};
    #translation{} ->
      {reply, {error, already_exist}, State}
  end;

handle_call({find, Id}, _, #state{translations = Translations} = State) ->
  {reply, maps:get(Id, Translations, undefined), State};

handle_call({finish, Id}, _, #state{translations = Translations, sid_to_id = SidToId, name_to_id = NameToId} = State) ->
  case maps:get(Id, Translations, undefined) of
    undefined ->
      {reply, ok, State};
    #translation{session_id = undefined} ->
      {reply, ok, State#state{translations = maps:remove(Id, Translations)}};
    #translation{session_id = Sid, session_pid = SessionPid, filename = Name} ->
      (catch rtmp_session:reject_connection(SessionPid)),
      {reply, ok, State#state{translations = maps:remove(Id, Translations), sid_to_id = maps:remove(Sid, SidToId), name_to_id = maps:remove(Name, NameToId)}}
  end;

handle_call({publish, SessionId}, _, #state{translations = Translations, sid_to_id = SidToId, name_to_id = NameToId} = State) ->
  Id = maps:get(SessionId, SidToId),
  case maps:get(Id, Translations) of
    #translation{filename = undefined} = Translation ->
      Filename = lists:flatten(io_lib:format("~s/~p.flv", [ulitos_app:get_var(dpo, file_dir, "."), Id])),
      {reply, Filename, State#state{translations = maps:put(Id, Translation#translation{filename = Filename}, Translations), name_to_id = maps:put(iolist_to_binary(Filename), Id, NameToId)}};
    #translation{filename = Filename} ->
      {reply, Filename, State}
  end;

handle_call({list}, _ , #state{translations = Translations} = State) ->
  {reply, maps:values(Translations), State};

handle_call(Req, _, State) ->
  {error, {unhandled, Req}, State}.

handle_cast({stream_started, Name, Media}, #state{translations = Translations, name_to_id = NameToId} = State) ->
  case maps:get(Name, NameToId, undefined) of
    undefined ->
      {noreply, State};
    Id ->
      lager:info([{kind,access}],"START_STREAM ~p~n", [Id]),
      Translation = maps:get(Id, Translations),
      {noreply, State#state{translations = maps:put(Id, Translation#translation{media = Media}, Translations)}}
  end;

handle_cast({stream_stopped, Name}, #state{translations = Translations, name_to_id = NameToId} = State) ->
  case maps:get(Name, NameToId, undefined) of
    undefined ->
      {noreply, State};
    Id ->
      lager:info([{kind,access}],"STOP_STREAM ~p~n", [Id]),
      Translation = maps:get(Id, Translations),
      {noreply, State#state{translations = maps:put(Id, Translation#translation{media = undefined}, Translations)}}
  end;

handle_cast({user_disconnected, SessionId}, #state{translations = Translations, sid_to_id = SidToId} = State) ->
  case maps:get(SessionId, SidToId, undefined) of
    undefined ->
      {noreply, State};
    Id ->
      ?D({user_disconnected, SessionId}),
      Translation = maps:get(Id, Translations),
      {noreply, State#state{translations = maps:put(Id, Translation#translation{session_id = undefined, session_pid = undefined, media = undefined}, Translations), sid_to_id = maps:remove(SessionId, SidToId)}}
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
    {"/hls/dpo/:id/:filename", [{id, int}], dpo_hls_handler, []}
  ],
  ems_http:add_routes(Routes).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(setup(F), {setup, fun setup_/0, fun cleanup_/1, F}).

-define(TPID,list_to_pid("<0.12.13>")).

play_url_test() ->
  application:set_env(dpo, varnish_host, "http://var1.ru"), 
  ?assertEqual(<<"http://var1.ru/hls/path/name.m3u8">>,play_url("path/name")),
  ?assertEqual(<<"http://var1.ru/hls/path/name.m3u8">>,play_url(<<"path/name">>)).

setup_() ->
  meck:new(rtmp_session,[non_strict]),
  meck:expect(rtmp_session, reject_connection, fun(_X) -> dpo_server:stream_stopped(?TPID) end),
  meck:new(hls_media,[non_strict]),
  meck:expect(hls_media, write_vod_hls, fun(_,_,_,_) -> ok end),
  lager:start(),
  dpo:start().

cleanup_(_) ->
  meck:unload(rtmp_session),
  meck:unload(hls_media),
  application:stop(lager),
  file:delete(ulitos_app:get_var(dpo,dets_file,"./dets")),
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
    ?_assertEqual({ok,play_url("test")}, dpo_server:add("test"))
  ].

add_stream_params_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  {ok,#translation{play_url=Url, id = Count}} = dpo_server:find("test"),
  [
    ?_assertEqual(play_url("test"),Url),
    ?_assertEqual(1,Count)
  ].

add_dup_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  [
    ?_assertEqual({error, already_exist}, dpo_server:add("test"))
  ].

list_streams_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  {ok,_} = dpo_server:add("test2"),
  [
    ?_assertEqual(2, length(dpo_server:list()))
  ].

finish_stream_test_() ->
  [
    {"Close existing stream",
      ?setup(fun close_stream_t_/1)},
    {"Close unexisting stream",
      ?setup(fun close_unex_stream_t_/1)},
    {"Finish stream",
      ?setup(fun finish_stream_t_/1)},
    {"Finish record stream",
      ?setup(fun finish_record_stream_t_/1)}
  ].

close_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  Res = dpo_server:close("test"),
  Size = length(dpo_server:list()),
  [
    ?_assertEqual(ok, Res)
    ,?_assertEqual(1, Size)
  ].

close_unex_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  [
    ?_assertEqual({error, not_found}, dpo_server:close("test2"))
    ,?_assertEqual(1, length(dpo_server:list()))
  ].

finish_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  [
    ?_assertEqual(ok, dpo_server:finish("test"))
    ,?_assertEqual(0, length(dpo_server:list()))
  ].

finish_record_stream_t_(_) ->
  {ok,_} = dpo_server:add("t"),
  FileDir = code:priv_dir(dpo)++"/tmp",
  filelib:ensure_dir(FileDir++"/t"),
  application:set_env(dpo, file_dir, FileDir),
  Res = file:write_file(FileDir++"/t.flv",[]),
  application:set_env(dpo, aws_bucket, "b"),
  application:set_env(dpo, aws_dir, "h"), 
  dpo_saver:reload(),
  [
    ?_assertEqual(ok,Res),
    ?_assert(filelib:is_regular(FileDir++"/t.flv")),
    ?_assertEqual({ok, <<"http://b.s3.amazonaws.com/h/t/playlist.m3u8">>},dpo_server:finish("t"))
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
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,<<"test">>),
  {ok,#translation{live=State}} = dpo_server:find("test"),
  [
    ?_assert(State)
  ].

stop_live_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,<<"test">>),
  {ok, #translation{live=Was}} = dpo_server:find("test"),
  dpo_server:stream_stopped(?TPID),
  {ok,#translation{live=State}} = dpo_server:find("test"),
  [
    ?_assert(Was),
    ?_assertNot(State)
  ].

close_live_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,<<"test">>),
  ok = dpo_server:close("test"),
  {ok,#translation{live=State}} = dpo_server:find("test"),
  [
   ?_assertNot(State)
  ].

finish_live_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,<<"test">>),
  ok = dpo_server:finish("test"),
  [
    ?_assertEqual(undefined,dpo_server:find("test"))
  ].

authorization_test_() ->
  [
    {"Authorize succes",
      ?setup(fun auth_stream_t_/1)},
    {"Authorize reject unregistered",
      ?setup(fun auth_fail_t_/1)},
    {"Authorize reject started",
      ?setup(fun auth_fail_started_t_/1)}
  ].

auth_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  {ok,_} = dpo_server:add("path/to/test"),
  [
    ?_assertEqual(ok, dpo_server:authorize_publish("test",#rtmp_session{session_id=1},?TPID))
    ,?_assertEqual(ok, dpo_server:authorize_publish("path/to/test",#rtmp_session{session_id=2},?TPID))
  ].

auth_fail_t_(_) ->
  [
    ?_assertEqual({error,not_found}, dpo_server:authorize_publish("test",#rtmp_session{session_id=1},?TPID))
  ].

auth_fail_started_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,<<"test">>),
  [
    ?_assertEqual({error,already_started}, dpo_server:authorize_publish("test",#rtmp_session{session_id=1},?TPID))
  ].


dets_test_() ->
  [
    {"Load from dets on normal app start",
      ?setup(fun load_dets_appstart_t_/1)
    }
  ].

load_dets_appstart_t_(_) ->
  dpo_server:add("test"),
  dpo:stop(),
  dpo:start(),
  [
    ?_assertEqual(1, length(dpo_server:list()))
  ].


-endif.