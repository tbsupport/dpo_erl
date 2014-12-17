%%% @doc
%%% Handle Erlyvideo events:
%%% <ul>
%%% <li> user_connected </li>
%%% <li> user_disconnected </li>
%%% <li> user_play </li>
%%% <li> user_stop </li>
%%% <li> stream_created </li>
%%% <li> stream_started </li>
%%% <li> stream_source_lost </li>
%%% <li> stream_source_requested </li>
%%% <li> stream_stopped </li>
%%% <li> stream_slow_media </li>
%%% </ul>
%%% @end

-module(dpo_event_handler).
-behaviour(gen_server).
-include_lib("dpo.hrl").
-include_lib("../include/erlyvideo.hrl").

-export([start_link/0, listen/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_event/2, handle_info/2, terminate/2, code_change/3]).

start_link() ->
  ?I(start_event_sup),
  Pid = spawn_link(?MODULE, listen, []),
  {ok,Pid}.

%% @private

listen() ->
  ?I({ems_event, code:is_loaded(ems_event)}),
  (catch ?I({ems_event_handler,ems_event:add_sup_handler(?MODULE, [])})),
  receive
    Msg -> ?E({this_should_not_happen, Msg})
  end.

init([]) ->
  ?I("Starting dpo_event_handler"),
  {ok, []}.



handle_event(#erlyvideo_event{event = user_connected, session_id = _SessionId}, State) ->
  %% do nothing for now
  {ok, State};


handle_event(#erlyvideo_event{event = user_disconnected, session_id = SessionId} = _E, State) ->
  dpo_server:user_disconnected(SessionId),
  {ok, State};


handle_event(#erlyvideo_event{event = stream_created, options = _Opts, stream = _Media, stream_name = _Name}, State) ->
  %% do nothing for now
  {ok, State};


handle_event(#erlyvideo_event{event = stream_started, stream = Media, stream_name = Name}, State) ->
  dpo_server:stream_started(Name, Media),
  {ok, State};


handle_event(#erlyvideo_event{event = stream_stopped, stream_name = Name}, State) ->
  dpo_server:stream_stopped(Name),
  {ok, State};


handle_event(_Event, State) ->
  {ok, State}.

handle_call(Request, _From, State) ->
  {ok, Request, State}.

handle_cast(Request, State) ->
  {ok, Request, State}.

handle_info(_Info, State) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.