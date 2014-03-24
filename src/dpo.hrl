-define(D(X), lager:debug("~p:~p ~p",[?MODULE, ?LINE, X])).
-define(I(X), lager:info("~p:~p ~p",[?MODULE, ?LINE, X])).
-define(E(X), lager:error("~p:~p ~p",[?MODULE, ?LINE, X])).


-record(translation, {
  id :: non_neg_integer(),
  session_id :: non_neg_integer(),
  socket :: pid(),
  session_pid ::pid(),
  media_id :: pid(),
  name :: binary(),
  play_url ::string(),
  live = false ::boolean()
}).