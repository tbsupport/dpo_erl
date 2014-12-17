-module(translations_handler).

-include_lib("../dpo.hrl").

-export([
  init/2,
  allowed_methods/2,
  malformed_request/2,
  is_authorized/2,
  content_types_provided/2,
  resource_exists/2,
  translation_status/2,
  delete_resource/2,
  delete_completed/2
]).

-record(state, {
  id :: non_neg_integer(),
  translation :: #translation{}
}).

init(Req, _Opts) ->
  {cowboy_rest, Req, #state{}}.

allowed_methods(Req, State) ->
  {[<<"GET">>, <<"DELETE">>], Req, State}.

malformed_request(Req, #state{} = State) ->
  Id = cowboy_req:binding(id, Req),
  case cowboy_req:method(Req) of
    <<"GET">> ->
      {false, Req, State#state{id = Id}};
    <<"DELETE">> ->
      if
        Id =:= undefined -> {true, Req, State};
        true -> {false, Req, State#state{id = Id}}
      end
  end.

is_authorized(Req, State) ->
  ApiKey = cowboy_req:header(<<"x-api-key">>, Req),
  Reply =
    case ulitos_app:get_var(dpo, api_key) of
      ApiKey -> true;
      _ -> {false, <<"">>}
    end,
  {Reply, Req, State}.

content_types_provided(Req, State) ->
  {[{{<<"text">>, <<"html">>, '*'}, translation_status}],Req,State}.

resource_exists(Req, #state{id = undefined} = State) ->
  {true, Req, State};

resource_exists(Req, #state{id = Id} = State) ->
  case dpo_server:find(Id) of
    undefined ->
      {false, Req, State};
    Translation ->
      {true, Req, #state{translation = Translation} = State}
  end.


translation_status(Req, #state{id = undefined} = State) ->
  Translations =
    lists:map(
      fun(#translation{id = Id, media = undefined}) -> {[{id, Id}, {live, false}]};
         (#translation{id = Id}) -> {[{id, Id}, {live, true}]}
      end,
      dpo_server:list()),
  {jiffy:encode(Translations), cowboy_req:set_resp_header(<<"Content-Type">>, <<"application/json">>, Req), State};

translation_status(Req, #state{translation = #translation{id = Id, media = undefined}} = State) ->
  {jiffy:encode({[{id, Id}, {live, false}]}), cowboy_req:set_resp_header(<<"Content-Type">>, <<"application/json">>, Req), State};

translation_status(Req, #state{translation = #translation{id = Id}} = State) ->
  {jiffy:encode({[{id, Id}, {live, true}]}), cowboy_req:set_resp_header(<<"Content-Type">>, <<"application/json">>, Req), State}.

delete_resource(Req, #state{id = Id} = State) ->
  dpo_server:finish(Id),
  {true, Req, State}.

delete_completed(Req, #state{translation = #translation{filename = Filename}} = State) ->
  Resp = cowboy_req:set_resp_header(<<"content-type">>, <<"application/json">>, Req),
  {true, cowboy_req:set_resp_body(jiffy:encode({[{status, ok}, {filename, iolist_to_binary(Filename)}]}), Resp), State}.


