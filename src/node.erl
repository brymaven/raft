-module(node).

-behaviour(gen_fsm).
-include("raft_interface.hrl").

-export([init/1, start_link/2, handle_info/3, handle_event/3, handle_sync_event/4, terminate/2, stop/0]).
-export([code_change/4, terminate/3]).
-export([follower/2, follower/3, leader/2, leader/3, candidate/2, candidate/3]).


start_link(Node, Addresses) ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, node_state:new(Node, Addresses), []).

init(#state{timeout=Timeout} = State) ->
    Ref = gen_fsm:start_timer(Timeout, dusty),
    {ok, follower, State#state{timer_ref=Ref}}.

%% Invoked by leader to replicate log entries
append_entries(#state{node_id=Node, addresses=Addresses} = State) ->
    OtherNodes = [A || A <- Addresses, A /= Node],
    lists:foreach(
      fun(N) ->
              AppendEntry = node_state:leader_append_entry(N, State),
              gen_fsm:send_event({node, N}, AppendEntry)
      end, OtherNodes).

%% Heartbeat is just an append_entry without any data.
heartbeat(State) ->
    gen_fsm:start_timer(1000, heartbeat),
    append_entries(State).

log_unknown(Msg, StateName) ->
    io:format("Encountered unexpected event while running as ~p: ~p~n",
              [StateName, Msg]).

%% During timeout, start an election.
follower(timeout, #state{} = State) ->
    start_election(State);

follower({timeout, _Ref, dusty}, State) ->
    start_election(State);

%% TODO(bryant): Figure out to handle the timer
%% followers are completely passive.
follower(Msg, #state{node_id=Node, term=Term, timer_ref=TimerRef, timeout=Timeout} = State) ->
    case Msg of
        #append_entry{leader_id=From} = AppendEntry ->
            {Successful, NewState} = node_state:follower_next_state(State, AppendEntry),
            gen_fsm:send_event({node, From},
                               #append_response{success=Successful, node_id=Node, term=Term}),
            NextTimer = case Successful of
                            true ->
                                gen_fsm:cancel_timer(TimerRef),
                                gen_fsm:start_timer(Timeout, dusty);
                            _ -> TimerRef
                        end,
            {next_state, follower, NewState#state{timer_ref=NextTimer}};
        _Msg ->
            log_unknown(Msg, follower),
            {next_state, follower, State}
    end.

%% Timeout exhausted during leader state
leader({timeout, _Ref, _Msg}, State) ->
    heartbeat(State),
    {next_state, leader, State};

%% Handles client calls
leader(#client_call{from=From, command=Command}, #state{term=Term,log=Log} = State) ->
    NextIndex = array:size(Log),
    NextLog = array:set(NextIndex, #entry{term=Term, command=Command}, Log),

    %% TODO(bryant): Need to get a synchronous response in time
    %%               Difficult because all of these calls are async right now
    %%               I would have to keep a reference to the client
    {client, From} ! {ok, some_message_from_leader},

    NextState = State#state{log=NextLog},
    {next_state, leader, NextState};


leader(Msg, State) ->
    case Msg of
        AppendResponse when is_record(AppendResponse, append_response) ->
            {next_state, leader, node_state:leader_next_state(State, AppendResponse)};
        VoteResponse when is_record(VoteResponse, vote_response) ->
            io:format("Already achieved a majority, but here's another vote~n"),
            {next_state, leader, State};
        _Msg ->
            log_unknown(Msg, leader),
            {next_state, leader, State}
    end.

step_down(#state{timer_ref=TimerRef, timeout=Timeout} = State) ->
    gen_fsm:cancel_timer(TimerRef),
    Ref = gen_fsm:start_timer(Timeout, dusty),
    {next_state, follower, State#state{timer_ref=Ref}}.

%% Timeout, so it assumes that there's been a split vote
candidate({timeout, _Ref, election}, State) ->
    start_election(State);

candidate(Msg, #state{node_id=Node, votes=Votes, log=Log,
                      timer_ref=TimerRef, timeout=Timeout,
                      term=Term, addresses=Addresses} = State) ->
    case Msg of
        %% TODO(bryant): Vote response could come any timer. They could just be spammed
        %% It is important to only keep the votes that correspond with this term
        #vote_response{vote_granted=true} ->
            if
                Votes > 1 ->
                    %% This is now the leader now
                    %% This timer must be a << election_timeout.
                    LastLogIndex = array:size(Log) - 1,
                    NextState = State#state{
                                  leader_id=Node,
                                  indexes=leader_index:new(Addresses, LastLogIndex)},
                    gen_fsm:cancel_timer(TimerRef),
                    heartbeat(NextState),
                    io:format("Node was just promoted to leader~n ~p nodes voted for ~n", [Votes]),
                    io:format("Leader for term ~p~n", [Term]),
                    {next_state, leader, NextState};
                true ->
                    {next_state, candidate, State#state{votes = Votes + 1}}
            end;
        #vote_response{vote_granted=false} ->
            io:format("Vote was rejected~n"),
            {next_state, candidate, State, Timeout};
        #append_entry{cur_term=CurTerm, leader_id=From} ->
            if
                CurTerm < Term ->
                    gen_fsm:send_event({node, From},
                                       #append_response{success=false, node_id=Node}),
                    {next_state, candidate, State, Timeout};
                true ->
                    io:format("Stepping down.~n"),
                    step_down(State)
            end;
        _Msg ->
            log_unknown(Msg, candidate),
            {next_state, candidate, State, Timeout}
    end.

%% Each server will vote only once. Need to persist to disk (TODO)
start_election(#state{term=CurrentTerm, node_id=Node, voted_for=VotedFor,
                      timeout=Timeout, timer_ref=TimerRef} = State) ->
    io:format("Node ~p just timed out. Starting election with term ~p~n", [Node,CurrentTerm + 1]),
    gen_fsm:cancel_timer(TimerRef),
    Ref = gen_fsm:start_timer(Timeout, election),
    vote(State),
    {next_state, candidate,
     State#state{term=CurrentTerm + 1, votes=1, timer_ref=Ref,
                 voted_for=array:set(CurrentTerm + 1, Node, VotedFor)}}.

vote(#state{term=Term, node_id=Node, log=Log, addresses=Addresses}) ->
    LastLogIndex = array:size(Log)-1,
    LastLogTerm  = (array:get(LastLogIndex, Log))#entry.term,
    Vote = #request_vote{term=Term, candidate_id=Node,
                         last_log_index=LastLogIndex,
                         last_log_term=LastLogTerm},
    broadcast_all_state(Node, Addresses, Vote).

%% Ignore sync events
leader(Event, _From, State) ->
    log_unknown(Event, leader),
    {next_state, leader, State}.

follower(Event, _From, State) ->
    log_unknown(Event, follower),
    {next_state, follower, State}.

candidate(Event, _From, State) ->
    log_unknown(Event, candidate),
    {next_state, candidate, State}.

terminate(_Reason, _LoopData) ->
    ok.

stop() ->
    gen_server:cast(?MODULE, stop).

handle_info(_I, StateName, State) ->
    {next_state, StateName, State}.

%% Useful debugging step for now. Checks the state of a node.
handle_event(status,
             StateName, #state{node_id=Node,log=Log,machine=Machine} = StateData) ->
    io:format("node: ~p is running as ~p~n", [Node, StateName]),
    io:format("node: ~p log: ~p~n", [Node, Log]),
    io:format("Machine: ~p~n", [Machine]),
    {next_state, StateName, StateData};

%% Handle RequestVote
handle_event(RequestVote, StateName, State)
  when is_record(RequestVote, request_vote) ->
    {VoteResponse, NewState} = node_state:next_state(RequestVote, State),
    gen_fsm:send_event({node, RequestVote#request_vote.candidate_id}, VoteResponse),
    case VoteResponse#vote_response.vote_granted of
        true ->
            step_down(NewState);
        false ->
            {next_state, StateName, NewState}
    end;

handle_event(AppendEntry, StateName, State) when is_record(AppendEntry, append_entry) ->
    {next_state, StateName, State}.


%% Points to current leader
handle_sync_event(leader, From, StateName, StateData) ->
    _Reply = gen_fsm:reply(From, StateData#state.leader_id),
    {next_state, StateName, StateData}.

terminate(normal, _State, _Data) ->
    ok.

code_change(_OldVsn, State, LoopData, _Extra) ->
    {ok, State, LoopData}.

broadcast_all_state(Node, Addresses, Msg) ->
    OtherNodes = [A || A <- Addresses, A /= Node],
    lists:foreach(fun(N) -> gen_fsm:send_all_state_event({node, N}, Msg) end, OtherNodes).
