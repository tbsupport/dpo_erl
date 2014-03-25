%%% @author Vova Dem
%%% @doc
%%% @end

-module(dpo_rtmp_handler).
-include_lib("dpo.hrl").
-include_lib("../include/rtmp.hrl").
-include_lib("../include/rtmp_session.hrl").

-export([publish/2,connect/2]).

publish(#rtmp_session{host = <<"dpo">>=Host} = Session, #rtmp_funcall{args = [null, Name |_]} = AMF) ->
  case dpo_server:authorize_publish(Name,Session,self()) of
    ok -> 
      lager:info([{kind,access}],"STREAM_PUBLISH ~p ~p~n",[Host,Name]),
      apps_recording:publish(Session, AMF#rtmp_funcall{args = [null,  Name, <<"append">>]});
    {error,_} ->
      reject_publish(Session,AMF)
  end;

publish(#rtmp_session{host = <<"hls">>=Host} = Session, #rtmp_funcall{args = [null, Name|_]} = AMF) ->
  case dpo_server:authorize_publish(Name,Session,self()) of
    ok -> 
      lager:info([{kind,access}],"STREAM_PUBLISH ~p ~p~n",[Host,Name]),
      apps_recording:publish(Session, AMF#rtmp_funcall{args = [null,  Name]});
    {error,_} ->
      reject_publish(Session,AMF)
  end;

publish(Session, AMF) ->
  reject_publish(Session,AMF).

connect(#rtmp_session{host = <<"dpo">>}, _AMF) ->
  unhandled;

connect(#rtmp_session{host = <<"hls">>}, _AMF) ->
  unhandled;

connect(#rtmp_session{host = _Host}=Session, _AMF) ->
  rtmp_session:reject_connection(Session).


%%--------- private -----------%%

reject_publish(#rtmp_session{host = Host} = Session,#rtmp_funcall{args = [null, Name|_]}) ->
  lager:info([{kind,access}],"STREAM_REJECT ~p ~p~n",[Host,Name]),
  rtmp_session:reject_connection(Session).


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
  dpo:stop().


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