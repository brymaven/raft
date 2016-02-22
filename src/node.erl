-module(node).
-export([init/1, start_link/2, handle_info/3, handle_event/3, handle_sync_event/4, terminate/2, stop/0]).
-export([code_change/4, terminate/3]).
-export([follower/2, follower/3, leader/2, leader/3, candidate/2, candidate/3]).

-behaviour(gen_fsm).
-include("raft_interface.hrl").
-export([start_election/1, vote/1]).
-export([follower_next_state/2]).

start_link(Node, Addresses) ->
    EmptyLog = array:new({fixed, false}),

    %% TODO(bryant): Log must be persisted on disk.
    State = #state{log=array:set(0, #entry{term=0, command=initialize}, EmptyLog),
                   node_id=Node, addresses=Addresses, timeout=timeout_value(10000)},
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, State, []).

%% Random value between [T, 2T].
%% This allows progress eventually be made during leader elections.
timeout_value(T) ->
    T + random:uniform(T).

init(#state{timeout=Timeout} = State) ->
    {ok, follower, State, Timeout}.

%% Candidate include log info in RequestVote RPCs (index & term) of last log entry
%% Voting server V denies vote if its log is "more complete"
%% last_term_v > last_term_c or lastterm_v == last_term_c and lastindex_v > lastindex_c
%% Winner will have most complete among cluster.
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
follower(Msg, #state{term=Term, timeout=Timeout} = State) ->
    case Msg of
        candidate ->
            io:format("~p~n", ["Follower -> Candidate"]),
            {next_state, candidate, State, Timeout};
        #append_entry{leader_id = From} = AppendEntry ->
            {Successful, NewState} = follower_next_state(State, AppendEntry),
            gen_fsm:send_event({node, From}, {Successful, Term}),
            {next_state, follower, NewState, Timeout};
        _Msg ->
            log_unknown(Msg, follower),
            {next_state, follower, State, Timeout}
    end.

%% Returns {success, NewState}
%% success will be true if follower contained entry matching prev_log_index, prev_log_term
%% TODO(bryant): Need to delete all entries after the last successful one.
follower_next_state(#state{log=Log} = State,
                    #append_entry{leader_id=LeaderId, command=Command,
                                  prev_term=PrevTerm, prev_index=PrevIndex,
                                  cur_term=CurTerm, cur_index=CurIndex}) ->
    case (array:size(Log) > PrevIndex) andalso
        ((array:get(PrevIndex, Log))#entry.term == PrevTerm) of
        true ->
            NewEntry = #entry{term=CurTerm,
                              command=Command},
            {true, State#state{log=array:set(CurIndex, NewEntry, Log),
                               leader_id = LeaderId}};
        false -> {false, State}
    end.

%% Timeout exhausted during leader state
leader({timeout, _Ref, _Msg}, #state{node_id=Node} = State) ->
    io:format("Node: ~p broadcasting another heartbeat~n", [Node]),
    heartbeat(State),
    {next_state, leader, State};

leader(Msg, State) ->
    case Msg of
        {_Success, _Term} ->
            {next_state, leader, State};
        _Msg ->
            log_unknown(Msg, leader),
            {next_state, leader, State}
    end.

%% Timeout, so it assumes that there's been a split vote
candidate(timeout, State) ->
    start_election(State);

candidate(Msg, #state{node_id=Node, votes=Votes, log=Log,
                      addresses=Addresses, timeout=Timeout} = State) ->
    case Msg of
        {vote_response, true, _Term} ->
            io:format("~p Accepted Vote from server~n", [Node]),
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
                    {next_state, candidate,
                     State#state{votes = Votes + 1},
                     Timeout}
            end;
        {vote_response, false, _Term} ->
            io:format("Vote was rejected~n"),
            {next_state, candidate, State, Timeout};
        #append_entry{} ->
            io:format("Received AppendEntry from a valid leader.~n Stepping down.~n"),
            {next_state, follower, State, Timeout};
        _Msg ->
            log_unknown(Msg, candidate),
            {next_state, candidate, State, Timeout}
    end.

%% Each server will vote only once. Need to persist to disk (TODO)
start_election(#state{term=CurrentTerm, node_id=Node, timeout=Timeout} = State) ->
    io:format("Node ~p just timed out. Starting election~n", [Node]),
    vote(State),
    {next_state, candidate,
     State#state{term=CurrentTerm + 1, votes=1, voted_for=Node}, Timeout}.

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
