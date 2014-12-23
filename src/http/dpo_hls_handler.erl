-module(dpo_hls_handler).

-include_lib("../dpo.hrl").

%% Cowboy_http_handler callbacks
-export([
  init/2
]).

init(Req, Opts) ->
  Id = cowboy_req:binding(id, Req),
  {Type, File} = validate_file(cowboy_req:binding(filename, Req)),
  Reply =
    case get_worker(Id) of
      undefined ->
        cowboy_req:reply(404, Req);
      {ok, Worker} ->
        case hls_worker:get(Worker, Type, File) of
          undefined ->
            cowboy_req:reply(404, Req);
          Object ->
            cowboy_req:reply(200, headers(Type), Object, Req)
        end
    end,
  {ok, Reply, Opts}.

validate_file(BFile) ->
  File = binary_to_list(BFile),
  case type(lists:reverse(File)) of
    invalid -> invalid;
    Type -> {Type, File}
  end.

get_worker(Id) ->
  case hls_server:get_stream({dpo, Id}) of
    undefined ->
      case dpo_server:find(Id) of
        undefined ->
          undefined;
        #translation{media = undefined} ->
          undefined;
        #translation{media = Media} ->
          hls_server:add_stream({dpo, Id}, Media)
      end;
    {ok, Pid} ->
      {ok, Pid}
  end.

type([$s, $t, $. | _ ]) -> segment;

type([$8, $u, $3, $m, $. | _ ]) -> playlist;

type(_) -> invalid.

headers(playlist) ->
  [{<<"Content-Type">>, <<"application/x-mpegURL">>}];

headers(segment) ->
  [{<<"Content-Type">>, <<"video/MP2T">>}].