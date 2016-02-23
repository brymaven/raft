-module(node).

-behaviour(gen_fsm).
-include("raft_interface.hrl").

-export([init/1, start_link/2, handle_info/3, handle_event/3, handle_sync_event/4, terminate/2, stop/0]).
-export([code_change/4, terminate/3]).
-export([follower/2, follower/3, leader/2, leader/3, candidate/2, candidate/3]).


start_link(Node, Addresses) ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, node_state:new(Node, Addresses), []).

init(#state{timeout=Timeout} = State) ->
    {ok, follower, State, Timeout}.

vote(#state{term=Term, node_id=Node, log=Log, addresses=Addresses}) ->
    LastLogIndex = array:size(Log)-1,
    LastLogTerm  = (array:get(LastLogIndex, Log))#entry.term,
    Vote = #request_vote{term=Term, candidate_id=Node,
                         last_log_index=LastLogIndex,
                         last_log_term=LastLogTerm},
    broadcast(Node, Addresses, {vote, Node, Vote}).

%% Invoked by leader to replicate log entries
append_entries(#state{term=Term, node_id=Node, addresses=Addresses}) ->
    %% TODO(bryant): prev_term, prev_index and cur_index will be per node specific
    broadcast(Node, Addresses, #append_entry{leader_id=Node,
                                  cur_term=Term,
                                  cur_index=0,
                                  command=0,
                                  prev_term=0,
                                  prev_index=0}).

%% Heartbeat is just an append_entry without any data.
heartbeat(State) ->
    gen_fsm:start_timer(5000, heartbeat),
    append_entries(State).

log_unknown(Msg, StateName) ->
    io:format("Encountered unexpected event while running as ~p: ~p~n",
              [StateName, Msg]).

follower({vote, From, #request_vote{term=Term, candidate_id=CandidateId}},
         #state{node_id = Node, term=CurrentTerm, voted_for=VotedFor} = State) ->
    VoteAtTerm = array:get(Term, VotedFor),
    if
        (Term < CurrentTerm) ->
            {next_state, follower, State};
        (VoteAtTerm == undefined) ->
            io:format("Node: ~p voted for server at term ~p~n", [Node, Term]),
            gen_fsm:send_event({node, From}, {vote_response, true, CurrentTerm}),
            {next_state, follower, State#state{voted_for=array:set(Term, CandidateId, VotedFor)}};
        true ->
            gen_fsm:send_event({node, From}, {vote_response, false, CurrentTerm}),
            {next_state, follower, State}
    end;

%% During timeout, start an election.
follower(timeout, #state{} = State) ->
    start_election(State);

%% followers are completely passive.
follower(Msg, #state{term=Term, node_id=NodeId, timeout=Timeout} = State) ->
    case Msg of
        #append_entry{leader_id = From} = AppendEntry ->
            {Successful, NewState} = node_state:follower_next_state(State, AppendEntry),
            gen_fsm:send_event({node, From},
                               #append_response{success=Successful, node_id=NodeId, term=Term}),
            {next_state, follower, NewState, Timeout};
        _Msg ->
            log_unknown(Msg, follower),
            {next_state, follower, State, Timeout}
    end.

%% Timeout exhausted during leader state
leader({timeout, _Ref, _Msg}, State) ->
    heartbeat(State),
    {next_state, leader, State};

leader(Msg, State) ->
    case Msg of
        #append_response{} = AppendResponse ->
            {next_state, leader, node_state:leader_next_state(State, AppendResponse)};
        _Msg ->
            log_unknown(Msg, leader),
            {next_state, leader, State}
    end.

%% Timeout, so it assumes that there's been a split vote
candidate(timeout, State) ->
    start_election(State);

candidate({vote, From, #request_vote{term=Term, candidate_id=CandidateId}},
         #state{node_id = Node, term=CurrentTerm, voted_for=VotedFor} = State) ->
    VoteAtTerm = array:get(Term, VotedFor),
    if
        (Term < CurrentTerm) ->
            {next_state, candidate, State};
        (VoteAtTerm == undefined) ->
            io:format("Node: ~p voted for server at term ~p~n", [Node, Term]),
            gen_fsm:send_event({node, From}, {vote_response, true, CurrentTerm}),
            {next_state, follower, State#state{voted_for=array:set(Term, CandidateId, VotedFor)}};
        true ->
            gen_fsm:send_event({node, From}, {vote_response, false, CurrentTerm}),
            {next_state, candidate, State}
    end;

candidate(Msg, #state{node_id=Node, votes=Votes, log=Log,
                      addresses=Addresses, timeout=Timeout, term=Term} = State) ->
    case Msg of
        {vote_response, true, _Term} ->
            if
                Votes > 1 ->
                    %% This is now the leader now
                    %% This timer must be a << election_timeout.
                    LastLogIndex = array:size(Log) - 1,
                    NextState = State#state{
                                  leader_id = Node,
                                  indexes = leader_index:new(Addresses, LastLogIndex)},
                    heartbeat(State),
                    {next_state, leader, NextState};
                true ->
                    {next_state, candidate, State#state{votes = Votes + 1}, Timeout}
            end;
        {vote_response, false, _Term} ->
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
                    {next_state, follower, State, Timeout}
            end;
        _Msg ->
            log_unknown(Msg, candidate),
            {next_state, candidate, State, Timeout}
    end.

%% Each server will vote only once. Need to persist to disk (TODO)
start_election(#state{term=CurrentTerm, node_id=Node, voted_for=VotedFor, timeout=Timeout} = State) ->
    io:format("Node ~p just timed out. Starting election~n", [Node]),
    vote(State),
    {next_state, candidate,
     State#state{term=CurrentTerm + 1, votes=1,
                 voted_for=array:set(CurrentTerm + 1, Node, VotedFor)}, Timeout}.

%% Handles client call
leader(Event, From, #state{machine=Machine} = StateData) ->
    {Result, NewMachine} = machine:apply(Event, Machine),
    _Reply = gen_fsm:reply(From, Result),
    {next_state, leader, StateData#state{machine = NewMachine}}.

%% Only leader handles sync events
%% followers and candidates just ignore message
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
handle_event(status, StateName, #state{node_id=Node, timeout=Timeout} = StateData) ->
    io:format("node: ~p is running as ~p~n", [Node, StateName]),
    {next_state, StateName, StateData, Timeout}.

%% Points to current leader
handle_sync_event(leader, From, StateName, StateData) ->
    _Reply = gen_fsm:reply(From, StateData#state.leader_id),
    {next_state, StateName, StateData}.

terminate(normal, _State, _Data) ->
    ok.

code_change(_OldVsn, State, LoopData, _Extra) ->
    {ok, State, LoopData}.

broadcast(Node, Addresses, Msg) ->
    OtherNodes = [A || A <- Addresses, A /= Node],
    lists:foreach(fun(N) -> gen_fsm:send_event({node, N}, Msg) end, OtherNodes).
