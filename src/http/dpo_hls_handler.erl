-module(dpo_hls_handler).

-include_lib("../dpo.hrl").

%% Cowboy_http_handler callbacks
-export([
  init/2
]).

init(Req, Opts) ->
  Id = cowboy_req:binding(id, Req),
  Name = cowboy_req:binding(name, Req),
  {Type, File} = validate_file(cowboy_req:binding(filename, Req)),
  Reply =
    case dpo_server:get_hls_stream(Id, Name) of
      undefined ->
        cowboy_req:reply(404, Req);
      {ok, Worker} ->
        case hls_worker:get(Worker, Type, File) of
          undefined ->
            cowboy_req:reply(404, Req);
          Object ->
            cowboy_req:reply(200, headers(Type), Object, Req)
        end;
      {playlist, Playlist} ->
        cowboy_req:reply(200, headers(Type), Playlist, Req)
    end,
  {ok, Reply, Opts}.

validate_file(BFile) ->
  File = binary_to_list(BFile),
  case type(lists:reverse(File)) of
    invalid -> invalid;
    Type -> {Type, File}
  end.

type([$s, $t, $. | _ ]) -> segment;

type([$8, $u, $3, $m, $. | _ ]) -> playlist;

type(_) -> invalid.

headers(playlist) ->
  [{<<"Content-Type">>, <<"application/x-mpegURL">>}];

headers(segment) ->
  [{<<"Content-Type">>, <<"video/MP2T">>}].