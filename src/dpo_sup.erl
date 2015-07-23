-module(dpo_sup).
-author("palkan").
-version(1.0).
-behaviour(supervisor).

-export([init/1, start_link/0]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	 Supervisors = [
		 {dpo_server,
        {dpo_server, start_link, []},
        permanent,
        2000,
        worker,
        []
		 },
		 {dpo_saver,
        {dpo_saver, start_link, []},
        permanent,
        2000,
        worker,
        []
		 },
		 {dpo_event_handler,
        {dpo_event_handler, start_link, []},
        permanent,
        2000,
        worker,
        []
		 }
	 ],
	{ok, {{one_for_one, 3, 10}, Supervisors}}.