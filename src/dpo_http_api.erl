%%% @author Vova Dem
%%% @doc
%%% API for DPO application.
%%% @end

-module(dpo_http_api).
-include_lib("dpo.hrl").

-export([http/4]).

-record(api_response,{
    status,
    data = undefined
  }).

-record(api_client,{
    permissions = user,
    request,
    method,
    post_params = []
  }).


http(_Host, Method, ["api","dpo"|Query], Req) ->
  Response = try
               handle_api_request(Query, #api_client{permissions = user, request = Req, method = Method})
             catch
               _:Type -> ?D([Type, Query]), #api_response{status = error}
             end,
  Req:ok([{'Content-Type', "application/json"}], [jiffy:encode(api_response_to_proplist(Response))]);

http(_Host, _Method, _Path, _Req) ->
  unhandled.

-spec handle_api_request(tuple(),#api_client{}) -> #api_response{}.

%% @doc
%% All admin requests require login and password
%% @end

handle_api_request(["admin"|Any], #api_client{permissions = user, request = Req} = Client) ->
  Args = Req:parse_post(),
  Name = proplists:get_value("api_admin_login", Args),
  Pass = proplists:get_value("api_admin_pass", Args),
  case check_auth(Name, Pass) of
    ok ->
      handle_api_request(["admin"|Any], Client#api_client{permissions = admin, post_params = Args});
    {error, Reason} ->
      #api_response{status = not_authorized, data = Reason}
  end;

%% @doc Register new stream. Request should contain "name" field. 
%% @end

handle_api_request(["admin","translations"], #api_client{permissions = admin, method = 'POST', post_params = Args}) ->
  Name = proplists:get_value("name",Args),
  Valid = is_valid_name(Name),
  if Valid ->
      case dpo_server:add(Name) of
        {ok,URL} -> #api_response{status = success, data = URL};
        {error,Error} -> #api_response{status = invalid, data = Error}
      end;
    true ->
      #api_response{status = invalid, data = invalid_name}
  end;

%% @doc Finish stream. Request should contain "name" field. 
%% @end

handle_api_request(["admin","translations","finish"], #api_client{permissions = admin, method = 'POST', post_params = Args}) ->
  Name = proplists:get_value("name",Args),
  case dpo_server:finish(Name) of
    ok -> #api_response{status = success};
    {error,Error} -> #api_response{status = invalid, data = Error}
  end;

%% @doc List all streams 
%% @end

handle_api_request(["translations"], #api_client{permissions = admin, method = 'GET'}) ->
  List = [ [{id,Id},{name,list_to_binary(Name)},{url,URL}] || #translation{id=Id,name=Name,play_url=URL} <- dpo_server:list()],
  #api_response{status = success, data = List};

handle_api_request(_Any, _Client) ->
  #api_response{status = invalid}.



%%------------- private ---------------%%

check_auth(undefined, _) ->
  {error, not_authorized};

check_auth(_, undefined) ->
  {error, not_authorized};

check_auth(Name,Pass) when is_binary(Name) ->
  check_auth(binary_to_list(Name),Pass);

check_auth(Name,Pass) when is_binary(Pass) ->
  check_auth(Name,binary_to_list(Pass));

check_auth(Name, Pass) ->
  case ulitos:binary_to_hex(crypto:hash(md5, Pass)) =:= ulitos:get_var(dpo, api_admin_pass_hash) andalso Name =:= ulitos:get_var(dpo, api_admin_login) of
    true ->
      ok;
    false ->
      {error, not_authorized}
  end.

api_response_to_proplist(#api_response{status = Status, data = Data}) ->
  {[{status, status_code(Status)},{data,Data}]}.

status_code(success) -> 200;
status_code(invalid) -> 403;
status_code(error) -> 500;
status_code(not_authorized) -> 401;
status_code(_) -> 503.


is_valid_name(Name) ->
  case ulitos:get_var(dpo,name_regexp) of
    undefined -> true;
    RegExp -> 
      {ok, Re} = re:compile(RegExp),
      case re:run(Name, Re) of
        {match,_} -> true;
        nomatch -> false
      end
  end.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(setup(F), {setup, fun setup_/0, fun cleanup_/1, F}).

-define(req(Params),{misultin_req, Params}).

setup_() ->
  meck:new(misultin_req,[non_strict]),
  meck:expect(misultin_req, parse_post, fun({misultin_req,List}) -> List end),
  meck:expect(misultin_req, ok, fun(_,B,_) -> B end),
  lager:start(),
  dpo:start(),
  application:set_env(dpo, name_regexp,"^[^\\/][\\w\\d\\_\\-\\/]+[^\\/]$"),
  application:set_env(dpo, api_admin_login, "admin"),
  application:set_env(dpo, api_admin_pass_hash, ulitos:binary_to_hex(crypto:hash(md5, <<"admin">>))). 

cleanup_(_) ->
  meck:unload(misultin_req),
  application:stop(lager),
  dpo:stop().

is_valid_name_test() ->
  application:set_env(dpo, name_regexp,"^[^\\/][\\w\\d\\_\\-\\/]+[^\\/]$"),
  ?assert(is_valid_name(<<"path_to/2014-03-25/victory">>)),
  ?assertNot(is_valid_name(<<"/path_to/2014-03-25/victory">>)),
  ?assertNot(is_valid_name(<<"/path_to/2014-03-25/victory.flv">>)),
  ?assertNot(is_valid_name(<<"/path_to/2014-03-25/victory/">>)).



api_test_() ->
  [
    {"Add stream name", ?setup(fun add_name_t_/1)},
    {"Add invalid stream name", ?setup(fun add_invalid_name_t_/1)},
    {"Finish stream", ?setup(fun finish_stream_t_/1)},
    {"Finish unregistered stream", ?setup(fun finish_unreg_stream_t_/1)}
  ].

json_response_test_() ->
  [
    {"HTTP Add stream name", ?setup(fun http_add_name_t_/1)},
    {"HTTP Wrong auth", ?setup(fun http_wrong_auth_t_/1)},
    {"HTTP Finish unregistered stream", ?setup(fun http_finish_unreg_stream_t_/1)}
  ].

auth_test_() ->
  [
    {"Wrong auth", ?setup(fun wrong_auth_t_/1)}
  ].

wrong_auth_t_(_) ->
  [
    ?_assertMatch(#api_response{status=not_authorized},handle_api_request(["admin","translations"],#api_client{method='GET',request = ?req([])}))
  ].

add_name_t_(_) ->
  [
    ?_assertMatch(#api_response{status=success},handle_api_request(["admin","translations"],#api_client{method='POST',request = ?req([{"api_admin_login",<<"admin">>},{"api_admin_pass",<<"admin">>},{"name",<<"path/to/test">>}])}))
  ].

add_invalid_name_t_(_) ->
  [
    ?_assertMatch(#api_response{status=invalid},handle_api_request(["admin","translations"],#api_client{method='POST',request = ?req([{"api_admin_login",<<"admin">>},{"api_admin_pass",<<"admin">>},{"name",<<"path/to/test.mp4">>}])}))
  ].

finish_stream_t_(_) ->
  dpo_server:add("path/test"),
  [
    ?_assertMatch(#api_response{status=success},handle_api_request(["admin","translations","finish"],#api_client{method='POST',request = ?req([{"api_admin_login",<<"admin">>},{"api_admin_pass",<<"admin">>},{"name",<<"path/test">>}])}))
  ].

finish_unreg_stream_t_(_) ->
  [
    ?_assertMatch(#api_response{status=invalid},handle_api_request(["admin","translations","finish"],#api_client{method='POST',request = ?req([{"api_admin_login",<<"admin">>},{"api_admin_pass",<<"admin">>},{"name",<<"path/test">>}])}))
  ].

http_wrong_auth_t_(_) ->
  [JSON] = http(<<>>,'GET', ["api","dpo","admin","translations"],?req([])),
  [
    ?_assertEqual(<<"{\"status\":401,\"data\":\"not_authorized\"}">>,JSON)
  ].


http_add_name_t_(_) ->
  [JSON] = http(<<>>,'POST', ["api","dpo","admin","translations"],?req([{"api_admin_login",<<"admin">>},{"api_admin_pass",<<"admin">>},{"name",<<"path/to/test">>}])),
  [
    ?_assertMatch(<<"{\"status\":200,\"data\":",_Rest/binary>>,JSON)
  ].

http_finish_unreg_stream_t_(_) ->
  [JSON] = http(<<>>,'POST', ["api","dpo","admin","translations","finish"],?req([{"api_admin_login",<<"admin">>},{"api_admin_pass",<<"admin">>},{"name",<<"path/to/test">>}])),
  [
    ?_assertMatch(<<"{\"status\":403,\"data\":",_Rest/binary>>,JSON)
  ].

-endif.