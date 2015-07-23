-module(dpo_saver).

-include_lib("erlyvideo/include/log.hrl").

-behaviour(gen_server).

%% API
-export([start_link/0, save_recording/2, reload/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-define(AWS_URL(B,F),"http://"++B++".s3.amazonaws.com/"++F).

-record(state, {
  status = off :: on|off,
  queue = queue:new() ::queue:queue(),
  content_dir ::string(),
  aws_bucket ::string(),
  aws_dir ::string()
}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%% @doc
%% Move dir to aws bucket and send fyler task.
%% @end

-spec save_recording(Id::non_neg_integer(), Dir::string()) -> ok | queued | {error,Error::any()}.

save_recording(Id, Dir) ->
  gen_server:call(?SERVER,{save_recording, Id, Dir}).


%% @doc
%% Reload config vars and reinitialize
%% @end

reload() ->
  gen_server:call(?SERVER, reload).


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
  {ok, setup_state(#state{})}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------


handle_call(reload, _, State) ->
  {reply, ok, setup_state(State)};

handle_call(Request, _, #state{status = off} = State) ->
  ?D({call_while_off, Request}),
  {reply, {error, off}, State};


handle_call(Request, _, #state{queue = Queue} = State) ->
  ?D({queue_request, Request}),
  NewQueue = queue:in(Request, Queue),
  self() ! next_task,
  {reply, queued, State#state{queue = NewQueue}};

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------


handle_cast(Request, #state{status = off} = State) ->
  ?D({cast_while_off, Request}),
  {noreply, State};


handle_cast(_Msg, State) ->
  {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------


handle_info(next_task, #state{queue = Queue} = State) ->
  NewState = case queue:out(Queue) of
    {empty,_} -> ?D(no_more_tasks), State;
    {{value, Task}, Queue2} -> {reply,_,State_} = handle_task(Task, State#state{queue = Queue2}),
                             self() ! next_task,
                             State_
  end,
  {noreply, NewState};


handle_info(_Info, State) ->
  {noreply, State}.


%% @doc
%% Handle queued task.
%% @end

-spec handle_task(Task::any(),State::#state{}) -> {reply,Reply::any(),NewState::#state{}}.

handle_task({save_recording, Id, Dir}, #state{aws_bucket = Bucket, aws_dir = AwsDir, content_dir = CDir} = State) ->
  Pid = spawn(fun() -> do_upload(Id, Dir, Bucket, AwsDir, CDir) end),
  {reply, Pid, State};


handle_task(_Task, State) -> {reply, undefined, State}.


-spec setup_state(#state{}) -> #state{}.

setup_state(#state{queue = Queue}) ->
  Bucket = ulitos_app:get_var(dpo, aws_bucket,false),
  Dir = ulitos_app:get_var(dpo, aws_dir,false),
  ContentDir = ulitos_app:get_var(dpo, recording_dir),

  Status = case is_list(Bucket) and is_list(Dir) and is_list(ContentDir) of
             true -> on;
             false -> ?D({aws_config_not_found, Bucket, Dir, ContentDir}),
               off
           end,
  #state{queue = Queue, status = Status, aws_bucket = Bucket, aws_dir = Dir, content_dir = ContentDir}.


dir_is_fine(Dir, Path) -> lists:sublist(Path,length(Dir)) =:= Dir.

local_path(Dir, Path) -> lists:sublist(Path, length(Dir) + 1, length(Path)).

do_upload(Id, Dir, Bucket, AwsDir, CDir) ->
  case filelib:is_dir(Dir) and dir_is_fine(CDir, Dir) of
    true -> AWSPath = AwsDir++"/"++local_path(CDir, Dir),
      AWSFullPath = "s3://"++Bucket++"/"++AWSPath,
      Res = aws_cli:copy_folder(Dir, AWSFullPath),
      case aws_cli:dir_exists(AWSFullPath) of
        true ->
          ulitos_file:recursively_del_dir(Dir),
          dpo_api:recording_task(Id, ?AWS_URL(Bucket, AWSPath++"stream.flv"));
        false -> ?E({aws_sync_error, Res}),
          {error, aws_failed}
      end;
    _ -> ?E({dir_not_found, Dir}),
    {error, enoent}
  end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
  ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

dir_is_fine_test_() ->
    [
      ?_assertEqual(true,dir_is_fine("/users/user/","/users/user/path/to")),
      ?_assertEqual(true,dir_is_fine("","users/user/path/to")),
      ?_assertEqual(false,dir_is_fine("/users/user/","users/user/path/to"))
    ].

local_path_test() ->

      ?assertEqual("path/to",local_path("/users/user/","/users/user/path/to")),
      ?assertEqual("users/user/path/to",local_path("","users/user/path/to")),
      ?assertEqual("2/record_9/",local_path("/Users/palkan/Dev/erly/content/","/Users/palkan/Dev/erly/content/2/record_9/"))
    .

-endif.