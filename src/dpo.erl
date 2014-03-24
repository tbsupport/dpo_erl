-module(dpo).

-export([start/0, stop/0, upgrade/0, ping/0, reload_config/0, health_check/0]).

start() ->
    application:start(dpo).
  
stop() -> 
    application:stop(dpo),
    application:unload(dpo).

upgrade() ->
	ems:reload(dpo).

reload_config() ->
  ulitos:load_config(dpo,"dpo.conf"),
  dpo_server:config_reloaded().


ping() ->
	pong.

health_check() ->
	try dpo_server:status() of
		List -> {ok, List}
	catch
		throw:Throw -> Throw;
		error:Error -> Error;
		exit:Exit -> Exit
	end.


