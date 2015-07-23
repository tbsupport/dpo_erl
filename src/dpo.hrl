-record(dpo_stream, {
  media :: pid(),
  filename :: iolist(),
  options = [] :: proplists:proplist(),
  hls :: reference()
}).

-record(translation, {
  id :: non_neg_integer(),
  session_id :: non_neg_integer(),
  session_pid :: pid(),
  streams = #{} :: #{string() => #dpo_stream{}}
}).