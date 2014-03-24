-module(dpo_app).
-author("palkan").
-behaviour(application).
-version(1.0).

-export([start/2, stop/1, config_change/3]).

start(_Type, _Args) ->
    lager:info("Starting application: DPO translations"),
    ulitos:load_config(dpo,"dpo.conf"),
    dpo_sup:start_link().
  

stop(_S) ->
    ok.

config_change(_Changed, _New, _Remove) ->
    ok.
