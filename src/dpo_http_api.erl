%%% @author Vova Dem
%%% @doc
%%% API for DPO application.
%%% @end

-module(dpo_http_api).
-include_lib("dpo.hrl").
-export([handle_api_request/2]).

-record(api_response,{
    status,
    data
  }).

-record(api_client,{
    permissions = user,
    request
  }).

-spec handle_api_request(tuple(),#api_client{}) -> #api_response{}.

handle_api_request(["admin"|Any], #api_client{permissions = user, request = Req} = Client) ->
  Args = Req:parse_post(),
  Name = proplists:get_value("api_admin_login", Args),
  Pass = proplists:get_value("api_admin_pass", Args),
  case check_auth(Name, Pass) of
    ok ->
      handle_api_request(["admin"|Any], Client#api_client{permissions = admin});
    {error, Reason} ->
      #api_response{status = invalid, data = Reason}
  end;

handle_api_request(_Any, _Client) ->
  #api_response{status = invalid}.


check_auth(undefined, _) ->
  {error, wrong};

check_auth(_, undefined) ->
  {error, wrong};

check_auth(Name, Pass) ->
  case ulitos:binary_to_hex(crypto:hash(md5, Pass)) =:= ulitos:get_var(dpo, api_admin_pass_hash) andalso Name =:= ulitos:get_var(dpo, api_admin_login) of
    true ->
      ok;
    false ->
      {error, wrong}
  end.