-module(dpo_saver).
-author("palkan").

-include_lib("dpo.hrl").
-behaviour(gen_server).

%% API
-export([start_link/0, save_vod_hls/2, reload/0]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).

-define(AWS_URL(B,F),"http://"++filename:join([B++".s3.amazonaws.com",F])).

-define(HLS_VOD_DURATION, 10000).

-define(PLAYLIST, "playlist").

-record(state, {
  status = off :: on|off,
  queue = queue:new() ::queue(),
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
%% @end

-spec save_vod_hls(FileName::string(),StreamName::string()) -> ok | queued | {error,Error::any()}.

save_vod_hls(FileName,StreamName) ->
  gen_server:call(?SERVER,{save_hls,FileName,StreamName}).


%% @doc
%% Reload config vars and reinitialize
%% @end

reload() ->
  gen_server:call(?SERVER,reload).


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
  {ok,setup_state(#state{})}.

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

handle_call({save_hls,FileName,Name},_,#state{aws_bucket = Bucket, aws_dir = Dir} = State) ->
  hls_media:write_vod_hls(FileName, filename:join([ulitos:get_var(dpo, hls_dir,"."),Name]),?HLS_VOD_DURATION, [{playlist, ?PLAYLIST},{stream_name, Name},{file_name,FileName}]),
  URL = list_to_binary(?AWS_URL(Bucket, filename:join([Dir,Name,?PLAYLIST++".m3u8"]))),
  ?I({hls_vod_url, URL}),
  {reply, {ok, URL},State};

handle_call(reload,_,State) ->
  {reply, ok, setup_state(State)};

handle_call(Request,_,#state{status=off}=State) ->
  ?D({call_while_off, Request}),
  {reply,{error,off},State};

handle_call(_Request, _From, State) ->
  ?D({unknown_call, _Request}),
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

handle_cast(Request,#state{status=off}=State) ->
  ?D({cast_while_off, Request}),
  {noreply,State};


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


handle_info({hls_complete, Options}, #state{queue = Queue}=State) ->
  ?D({hls_complete, Options}), 
  NewQueue = queue:in({save_recording, proplists:get_value(path,Options), proplists:get_value(stream_name,Options),proplists:get_value(file_name,Options)},Queue),
  self() ! next_task,
  {noreply,State#state{queue = NewQueue}};

handle_info(next_task,#state{queue = Queue} = State) ->
  NewState = case queue:out(Queue) of
    {empty,_} -> ?D(no_more_tasks), State;
    {{value,Task},Queue2} -> {reply,_,State_} = handle_task(Task,State#state{queue = Queue2}),
                             self() ! next_task,
                             State_
  end,
  {noreply,NewState};


handle_info(_Info, State) ->
  {noreply, State}.


%% @doc
%% Handle queued task.
%% @end

-spec handle_task(Task::any(),State::#state{}) -> {reply,Reply::any(),NewState::#state{}}.

handle_task({save_recording,Path,Name,File},#state{aws_bucket=Bucket,aws_dir=AwsDir}=State) ->
  Reply = case filelib:is_dir(Path) of
            true -> AWSPath = filename:join(AwsDir,Name),
              AWSFullPath = "s3://"++Bucket++"/"++AWSPath,
              Res = aws_cli:copy_folder(Path,AWSFullPath),
              case aws_cli:dir_exists(AWSFullPath) of
                true ->
                  ?I({delete_dir_and_file, Path, Dir}),
                  file:delete(File),
                  ulitos_file:recursively_del_dir(Path);
                false -> ?E({aws_sync_error,Res}),
                  {error, aws_failed}
              end;
            _ -> ?D({dir_not_found,Path}),
                 {error, enoent}
          end,
  {reply,Reply,State};


handle_task(_Task,State) -> {reply,undefined,State}.


-spec setup_state(#state{}) -> #state{}.

setup_state(#state{queue = Queue}) ->
  Bucket = ulitos:get_var(dpo,aws_bucket,false),
  Dir = ulitos:get_var(dpo,aws_dir,false),

  Status = case is_list(Bucket) andalso is_list(Dir) of
             true -> on;
             false -> ?D({aws_config_not_found,Bucket,Dir}),
               off
           end,
  ?I({dpo_saver, setup, Bucket, Dir}),
  #state{queue = Queue, status=Status,aws_bucket=Bucket,aws_dir=Dir}.


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

-endif.