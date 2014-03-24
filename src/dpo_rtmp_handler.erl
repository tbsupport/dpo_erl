%%% @author Vova Dem
%%% @doc
%%% @end

-module(dpo_rtmp_handler).
-include_lib("dpo.hrl").
-include_lib("../include/rtmp.hrl").
-include_lib("../include/rtmp_session.hrl").

-export([publish/2]).

publish(#rtmp_session{host = <<"dpo">>=Host} = Session, #rtmp_funcall{args = [null, Name |_]} = AMF) ->
  lager:info([{kind,access}],"STREAM publish_record ~p ~p~n",[Host,Name]),
  apps_recording:publish(Session, AMF#rtmp_funcall{args = [null,  Name, <<"append">>]});

publish(#rtmp_session{host = <<"hls">>=Host} = Session, #rtmp_funcall{args = [null, Name|_]} = AMF) ->
  lager:info([{kind,access}],"STREAM publish ~p ~p~n",[Host,Name]),
  apps_recording:publish(Session, AMF#rtmp_funcall{args = [null,  Name]});

publish(#rtmp_session{host = Host} = Session, #rtmp_funcall{args = [null, Name|_]} = _AMF) ->
  lager:info([{kind,access}],"STREAM not_authorized_publish ~p ~p~n",[Host,Name]),
  rtmp_session:reject_connection(Session).