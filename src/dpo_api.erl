-module(dpo_api).

-include_lib("erlyvideo/include/log.hrl").

%% API
-export([check_auth_hash/1, recording_task/2]).

check_auth_hash(Hash) ->
  case api_client:post(http_auth_path, [{"token", Hash}]) of
    {ok, Json} ->
      Id = proplists:get_value(<<"id">>, Json),
      {ok, Id};
    {error, Reason} ->
      ?E({"error calling auth handler", Reason}),
      {error, Reason}
  end.

recording_task(Id, Path) ->
  case api_client:post(http_dpo_recording_path, [{id, Id}, {"url", Path}]) of
    {ok, _Json} ->
      ok;
    {error, Reason} ->
      ?E({"error calling save records handler", Reason}),
      {error, Reason}
  end.