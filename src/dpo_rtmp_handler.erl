%%% @author Vova Dem
%%% @doc
%%% @end

-module(dpo_rtmp_handler).
-include_lib("dpo.hrl").
-include_lib("../include/rtmp.hrl").
-include_lib("../include/rtmp_session.hrl").

-export([publish/2, connect/2]).

publish(_State, #rtmp_funcall{args = [null, null]}) ->
  unhandled;

publish(#rtmp_session{host = <<"dpo/", _Hash/binary>> = Host, session_id = SessionId} = Session, #rtmp_funcall{args = [null, _OrigName |_]} = AMF) ->
  lager:info([{kind,access}],"STREAM_PUBLISH ~p ~s~n",[Host, record]),
  Filename = dpo_server:publish(SessionId),
  apps_recording:publish(Session, AMF#rtmp_funcall{args = [null, Filename, <<"append">>]});

publish(#rtmp_session{host = <<"hls/", _Hash/binary>>=Host, session_id = SessionId} = Session, #rtmp_funcall{args = [null, _OrigName|_]} = AMF) ->
  lager:info([{kind,access}],"STREAM_PUBLISH ~p ~s~n", [Host, live]),
  Filename = dpo_server:publish(SessionId),
  apps_recording:publish(Session, AMF#rtmp_funcall{args = [null,  Filename]});

publish(_Session, _AMF) ->
  unhandled.

connect(#rtmp_session{host = <<"dpo/", Hash/binary>> = Host, session_id = SessionId} = Session, _AMF) ->
  case dpo_api:check_auth_hash(extract_name(Hash)) of
    {ok, Id} ->
      dpo_server:add(Id, SessionId, self()),
      lager:info([{kind,access}],"CONNECT ~p ~p~n", [Host, SessionId]),
      rtmp_session:accept_connection(Session);
    Other	->
      ?D({check_hash_failed, Other}),
      lager:info([{kind,access}],"LOGIN_REJECT wrong_hash ~p~n",[Hash]),
      unhandled
  end;

connect(#rtmp_session{host = <<"hls/", Hash/binary>> = Host, session_id = SessionId} = Session, _AMF) ->
  case dpo_api:check_auth_hash(extract_name(Hash)) of
    {ok, Id} ->
      dpo_server:add(Id, SessionId, self()),
      lager:info([{kind,access}],"CONNECT ~p ~p~n", [Host, SessionId]),
      rtmp_session:accept_connection(Session);
    Other	->
      ?D({check_hash_failed, Other}),
      lager:info([{kind,access}],"LOGIN_REJECT wrong_hash ~p~n",[Hash]),
      unhandled
  end;

connect(_Session, _AMF) ->
  unhandled.

%%--------- private -----------%%

%% @doc Remove query params from stream name
%% @end

-spec extract_name(binary()) -> binary().

extract_name(Name) ->
  {ok, Re} = re:compile("^([^\\?]+)\\?.+$"),
  case re:run(Name, Re, [{capture, all, binary}]) of
    {match, [_,Name2]} -> Name2;
    _ -> Name
  end.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-define(setup(F), {setup, fun setup_/0, fun cleanup_/1, F}).

setup_() ->
  meck:new(apps_recording,[non_strict]),
  meck:expect(apps_recording, publish, fun(_,#rtmp_funcall{args = [null|Args]}) -> Args end),
  meck:new(rtmp_session,[non_strict]),
  meck:expect(rtmp_session, reject_connection, fun(_X) -> rejected end),
  lager:start(),
  dpo:start().

cleanup_(_) ->
  meck:unload(apps_recording),
  meck:unload(rtmp_session),
  application:stop(lager),
  file:delete(ulitos_app:get_var(dpo,dets_file,"./dets")),
  dpo:stop().

extract_name_test() ->
  ?assertEqual(<<"path/name">>,extract_name(<<"path/name?var1=1&var2=2">>)),
  ?assertEqual(<<"path/name">>,extract_name(<<"path/name">>)).


publish_dpo_test_() ->
  [
    {"Publish DPO registered", ?setup(fun publish_dpo_t_/1)},
    {"Publish DPO unregistered", ?setup(fun publish_dpo_unregistered_t_/1)}
  ].

publish_hls_test_() ->
  [
    {"Publish HLS registered", ?setup(fun publish_hls_t_/1)},
    {"Publish HLS unregistered", ?setup(fun publish_hls_unregistered_t_/1)}
  ].

publish_other_test_() ->
  [
    {"Publish other registered", ?setup(fun publish_registered_t_/1)},
    {"Publish other unregistered", ?setup(fun publish_unregistered_t_/1)}
  ].

connect_test_() ->
  [
    {"Connect with verified host", ?setup(fun connect_normal_t_/1)},
    {"Connect with unknown host", ?setup(fun connect_unknown_t_/1)}
  ].

publish_dpo_t_(_) ->
  dpo_server:add(<<"test/path/name">>),
  [
    ?_assertEqual([<<"test/path/name">>,<<"append">>],publish(#rtmp_session{host= <<"dpo">>},#rtmp_funcall{args=[null,<<"test/path/name">>]}))
    ,?_assert(meck:validate(apps_recording))
  ].

publish_hls_t_(_) ->
  dpo_server:add(<<"test/path/name">>),
  [
    ?_assertEqual([<<"test/path/name">>],publish(#rtmp_session{host= <<"hls">>},#rtmp_funcall{args=[null,<<"test/path/name">>]}))
    ,?_assert(meck:validate(apps_recording))
  ].

publish_dpo_unregistered_t_(_) ->
  [
    ?_assertEqual(rejected,publish(#rtmp_session{host= <<"dpo">>},#rtmp_funcall{args=[null,<<"test/path/name">>]}))
    ,?_assert(meck:validate(rtmp_session))
  ].

publish_hls_unregistered_t_(_) ->
  [
    ?_assertEqual(rejected,publish(#rtmp_session{host= <<"hls">>},#rtmp_funcall{args=[null,<<"test/path/name">>]}))
    ,?_assert(meck:validate(rtmp_session))
  ].

publish_registered_t_(_) ->
  dpo_server:add(<<"test/path/name">>),
  [
    ?_assertEqual(rejected,publish(#rtmp_session{host= <<"testo">>},#rtmp_funcall{args=[null,<<"test/path/name">>]}))
    ,?_assert(meck:validate(rtmp_session))
  ].

publish_unregistered_t_(_) ->
  [
    ?_assertEqual(rejected,publish(#rtmp_session{host= <<"testo">>},#rtmp_funcall{args=[null,<<"test/path/name">>]}))
    ,?_assert(meck:validate(rtmp_session))
  ].

connect_normal_t_(_) ->
  ?_assertEqual(unhandled, connect(#rtmp_session{host= <<"dpo">>},#rtmp_funcall{})).

connect_unknown_t_(_) ->
  ?_assertEqual(rejected, connect(#rtmp_session{host= <<"testo">>},#rtmp_funcall{})).


-endif.