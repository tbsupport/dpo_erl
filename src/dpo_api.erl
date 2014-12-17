-module(dpo_api).

-include("dpo.hrl").

%% API
-export([check_auth_hash/1, recording_task/2]).

check_auth_hash(Hash) ->
  %%case api_client:post(http_auth_path, [{"token", Hash}]) of
    %%{ok, Json} ->
      %%#translation{
        %%id = proplists:get_value(<<"id">>, Json)
      %%};
    %%{error, Reason} ->
      %%?E({"error calling auth handler", Reason}),
      %%{error, Reason}
  %%end.
  {ok, binary_to_integer(Hash)}.

recording_task(Id, Path) ->
  case api_client:post(http_recording_path, [{"translation_id", Id}, {"url", Path}]) of
    {ok, _Json} ->
      ok;
    {error, Reason} ->
      ?E({"error calling save records handler", Reason}),
      {error, Reason}
  end.