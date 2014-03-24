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

-export([add/1, finish/1, close/1, find/1, list/0, authorize_publish/3, config_reloaded/0]).
-export([stream_started/2, stream_stopped/1]).
-export([status/0]).

-define(T_STREAMS, dpo_streams).

-record(state, {
  count = 1 ::non_neg_integer()
}).


start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  lager:info("Starting dpo_server"),
  ets:new(?T_STREAMS, [private, named_table, {keypos, #translation.name}]),
  {ok, #state{}}.


%% @doc
%% Handle config was reloaded event
%% @end

-spec config_reloaded() -> any().

config_reloaded()->
  ok.

%% @doc Find translation by name.
%% @end

-spec find(string()|binary()) -> {ok, #translation{}} | undefined.

find(Name) when is_binary(Name) ->
  find(binary_to_list(Name));

find(Name) ->
  gen_server:call(?MODULE,{find,Name}).

%% @doc
%% Disconnect stream session
%% @end

-spec close(binary()|string()) -> ok|false.

close(Name) when is_binary(Name) ->
  close(binary_to_list(Name));

close(Name) ->
  gen_server:call(?MODULE,{close,Name}).

%% @doc
%%  Remove stream from registered list and disconnect
%% @end

finish(Name) when is_binary(Name) ->
  finish(binary_to_list(Name));

finish(Name) ->
  gen_server:call(?MODULE,{finish,Name}).

status() ->
  ok.

list() ->
  gen_server:call(?MODULE,{list}).

%% @doc Add stream to whitelist.
%% @end

-spec add(string()|binary()) -> ok|{error,any()}.

add(Name) when is_binary(Name) ->
  add(binary_to_list(Name));

add(Name) ->
  gen_server:call(?MODULE, {add, Name}).

%% @doc Check whether stream is registered and if so add session info to it  
%% @end

-spec authorize_publish(string(), #rtmp_session{}, pid()) -> {ok,PlayUrl::string()} | {error,Reason::atom()}.

authorize_publish(Name,#rtmp_session{socket = Socket, session_id = SessionId},Pid) ->
  gen_server:call(?MODULE,{authorize, Name, SessionId, Socket, Pid}).


%% @doc Stream started event handler
%% @end

-spec stream_started(pid(), string()) -> ok.

stream_started(Media, Name) ->
  gen_server:cast(?MODULE,{stream_started,Media,Name}).

%% @doc Stream stopped event handler
%% @end

-spec stream_stopped(pid()) -> ok.

stream_stopped(Media) ->
  gen_server:cast(?MODULE,{stream_stopped,Media}).


%%%----------- gen_server handlers ------------%%%

handle_call({add, Name}, _, #state{count=Count}=State) ->
  case find_(Name) of
    {ok, _Rec} -> 
      ?D({stream_exists}),
      {reply, {error, eexists}, State};
    undefined ->
      Url = play_url(Name),
      NewStream = #translation{name = Name, id = Count, play_url = Url},
      ets:insert(?T_STREAMS, NewStream),
      lager:info([{kind,access}],"REGISTER_STREAM ~p ~s~n", [Count, Name]),
      {reply, {ok, Url}, State#state{count = Count+1}}
  end;

handle_call({find, Name},_,State) ->
  {reply,find_(Name),State};

handle_call({close, Name},_,State) ->
  {reply,close_(Name),State};

handle_call({finish, Name},_,State) ->
  {reply,finish_(Name),State};

handle_call({list},_,State) ->
  {reply,ets:tab2list(?T_STREAMS),State};

handle_call({authorize,Name,SessionId,Socket,Pid},_,State) ->
  Reply = case find_(Name) of
    {ok, #translation{live = true}} -> 
      ?D({already_started,Name}),
      {error, already_started};
    {ok, #translation{}=Rec} ->
      ets:insert(?T_STREAMS, Rec#translation{session_id = SessionId, socket = Socket, session_pid = Pid}),
      ok;
    undefined -> 
      ?D({stream_not_found,Name}),
      {error, not_found}
  end,
  {reply,Reply,State};

handle_call(Req, _, State) ->
  {error, {unhandled, Req}, State}.

handle_cast({stream_started,Media, Name},State) ->
  case find_(Name) of
    {ok, #translation{}=Rec} -> 
      lager:info([{kind,access}],"START_STREAM ~s~n", [Name]),
      ets:insert(?T_STREAMS, Rec#translation{media_id = Media, live = true});
    _ -> ?D({unregistered_stream, Name})
  end,
  {noreply,State};

handle_cast({stream_stopped,Media},State) ->
  case ets:match_object(?T_STREAMS, #translation{media_id=Media,_='_'}) of
    [#translation{name=Name}=Rec] -> 
      lager:info([{kind,access}],"STOP_STREAM ~s~n", [Name]),
      ets:insert(?T_STREAMS, Rec#translation{media_id = undefined, live = false});
    _ -> ?D({unregistered_stream, Media})
  end,
  {noreply,State};

handle_cast(Cast, State) ->
  {error, {unknown_cast, Cast}, State}.

handle_info(stop, State) ->
  {stop, normal, State};

handle_info(Info, State) ->
  ?D({unknown_info, Info}),
  {noreply, State}.

terminate(_, _) -> ok.
code_change(_, State, _) -> {ok, State}.



%%% --------------- private ----------------- %%%

-spec play_url(string()|binary()) -> binary().

play_url(Name) ->
  list_to_binary(io_lib:format("~s/hls/~s.m3u8",[ulitos:get_var(dpo, varnish_host),Name])).

find_(Name) ->
  case ets:lookup(?T_STREAMS, Name) of
    [#translation{}=Rec] -> {ok, Rec};
    [] -> undefined
  end. 

close_(Name) ->
  case find_(Name) of
    {ok,#translation{session_pid=Pid, live = true}} -> 
      lager:info([{kind,access}],"CLOSE_STREAM ~s~n", [Name]),
      (catch rtmp_session:reject_connection(Pid)),
     ok;
    {ok, _} -> ?D({stream_is_not_active, Name}),
        ok;
    Else -> ?D({stream_not_registered,Name,Else}),
        {error, not_found}
  end.

finish_(Name) ->
  case close_(Name) of
    ok -> 
      lager:info([{kind,access}],"FINISH_STREAM ~s~n", [Name]),
      ets:delete(?T_STREAMS,Name),
      ok;
    {error, not_active} -> 
      lager:info([{kind,access}],"FINISH_STREAM ~s~n", [Name]),
      ets:delete(?T_STREAMS,Name),
      ok;
    Else -> 
      ?D({finish_failed,Name}),
      Else
  end.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(setup(F), {setup, fun setup_/0, fun cleanup_/1, F}).

-define(TPID,list_to_pid("<0.12.13>")).

play_url_test() ->
  application:set_env(dpo, varnish_host, "http://var1.ru"), 
  ?assertEqual(<<"http://var1.ru/hls/path/name.m3u8">>,play_url("path/name")),
  ?assertEqual(<<"http://var1.ru/hls/path/name.m3u8">>,play_url(<<"path/name">>)).

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


finish_stream_test_() ->
  [
    {"Close existing stream",
      ?setup(fun close_stream_t_/1)},
    {"Close unexisting stream",
      ?setup(fun close_unex_stream_t_/1)},
    {"Finish stream",
      ?setup(fun finish_stream_t_/1)}
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

authorization_test_() ->
  [
    {"Authorize succes",
      ?setup(fun auth_stream_t_/1)},
    {"Authorize reject unregistered",
      ?setup(fun auth_fail_t_/1)},
    {"Authorize reject started",
      ?setup(fun auth_fail_started_t_/1)}
  ].
    

setup_() ->
  lager:start(),
  dpo:start().

cleanup_(_) ->
  application:stop(lager),
  dpo:stop().

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
    ?_assertEqual({error, eexists}, dpo_server:add("test"))
  ].

list_streams_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  {ok,_} = dpo_server:add("test2"),
  [
    ?_assertEqual(2, length(dpo_server:list()))
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

add_live_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,"test"),
  {ok,#translation{live=State}} = dpo_server:find("test"),
  [
    ?_assert(State)
  ].

stop_live_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,"test"),
  {ok, #translation{live=Was}} = dpo_server:find("test"),
  dpo_server:stream_stopped(?TPID),
  {ok,#translation{live=State}} = dpo_server:find("test"),
  [
    ?_assert(Was),
    ?_assertNot(State)
  ].

close_live_stream_t_(_) ->
  meck:new(rtmp_session,[non_strict]),
  meck:expect(rtmp_session, reject_connection, fun(_X) -> dpo_server:stream_stopped(?TPID) end),
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,"test"),
  ok = dpo_server:close("test"),
  {ok,#translation{live=State}} = dpo_server:find("test"),
  [
   ?_assertNot(State)
  ].

finish_live_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,"test"),
  ok = dpo_server:finish("test"),
  [
    ?_assertEqual(undefined,dpo_server:find("test"))
  ].


auth_stream_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  [
    ?_assertEqual(ok, dpo_server:authorize_publish("test",#rtmp_session{session_id=1},?TPID))
  ].

auth_fail_t_(_) ->
  [
    ?_assertEqual({error,not_found}, dpo_server:authorize_publish("test",#rtmp_session{session_id=1},?TPID))
  ].

auth_fail_started_t_(_) ->
  {ok,_} = dpo_server:add("test"),
  dpo_server:stream_started(?TPID,"test"),
  [
    ?_assertEqual({error,already_started}, dpo_server:authorize_publish("test",#rtmp_session{session_id=1},?TPID))
  ].

-endif.