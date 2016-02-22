-module(node).
-export([init/1, start_link/2, handle_info/3, handle_event/3, handle_sync_event/4, terminate/2, stop/0]).
-export([code_change/4, terminate/3]).
-export([follower/2, leader/2, candidate/2]).

-behaviour(gen_fsm).
-include("raft_interface.hrl").
-import(rand, [uniform/1]).
-export([start_election/1, vote/1]).
-export([follower_next_state/2]).

%% Have an in memory log
%% Client passes command
  %% 1. Command put in log in machine
  %% 2. Once replicated in log, can be passed to the state machine for execution.
  %% 3. Once state machine executed, can return command to client

%% When modifying log, must persist to disk before returning.
%% When entry is stored in a majority of servers, we say it is commited.

start_link(Node, Addresses) ->
    io:format("Starting new process from node module ~p~n", [Node]),
    EmptyLog = array:new({fixed, false}),

    %% TODO(bryant): Log must be persisted on disk.
    State = #state{log=array:set(0, #entry{term = 0, command = initialize}, EmptyLog),
                   node_id=Node, addresses = Addresses, timeout = timeout_value(10000)},
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, State, []).

%% Random value between [T, 2T].
timeout_value(T) ->
    T + rand:uniform(T).

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
    io:format("~p~n", [Vote]),
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

follower({vote, From, #request_vote{term=Term, candidate_id=CandidateId}},
         #state{node_id = Node, term=CurrentTerm, voted_for=VotedFor} = State) ->
    if
        (Term < CurrentTerm) ->
            %%gen_fsm:send_event(From, {vote_response, false, CurrentTerm}),
            {next_state, follower, State};
        (VotedFor == undefined) ->
            io:format("Node: ~p sending a response of ~p~n", [Node, {vote_response, true, CurrentTerm}]),
            gen_fsm:send_event({node, From}, {vote_response, true, CurrentTerm}),
            {next_state, follower, State#state{voted_for=CandidateId}};
        true ->
            gen_fsm:send_event({node, From}, {vote_response, false, CurrentTerm}),
            {next_state, follower, State}
    end;

%% During timeout, will start an election to see if it should become a leader.
%% Increment Current Term
%% Change to Candidate State
%% Vote for self
%% Send RequestVote RPC too all other servers
follower(timeout, #state{} = State) ->
    start_election(State);

%% Most servers will be in follower state at a time
%% Can go to Candidate once there is a timeout
%% Initial state for servers

%% followers are completely passive.
%% For it to believe it's a follower, it must receive something from the server
%% Only way it would know is if it gets a heartbeat.
follower(Msg, #state{term = Term, node_id = Node, timeout=Timeout} = State) ->
    case Msg of
        candidate ->
            io:format("~p~n", ["Follower -> Candidate"]),
            {next_state, candidate, State, Timeout()};
        #append_entry{leader_id = From} = AppendEntry ->
            {Successful, NewState} = follower_next_state(State, AppendEntry),
            gen_fsm:send_event({node, From}, {Successful, Term}),
            {next_state, follower, NewState, Timeout()};
        _Msg ->
            io:format("Unknown Message: ~p~n", [Msg]),
            {next_state, follower, State, Timeout()}
    end.

%% Returns {success, NewState}
%% success will be true if follower contained entry matching prev_log_index, prev_log_term
%% TODO(bryant): Need to delete all entries after the last successful one. I'm not sure how to really delete entries from arrays. An idea is to keep track of a valid index
follower_next_state(#state{log = Log} = State,
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
leader({timeout, _Ref, _Msg}, #state{node_id = Node} = State) ->
    io:format("Node: ~p broadcasting another heartbeat~n", [Node]),
    heartbeat(State),
    {next_state, leader, State};

leader(Msg, State) ->
    io:format("Message: ~p to leader is probably some timeout~n", [Msg]),
    case Msg of
        follower ->
            io:format("~p~n", ["Leader -> Follower"]),
            {next_state, follower, State};
        _Msg ->
            io:format("Unknown message on leader: ~p~n", [Msg]),
            {next_state, leader, State}
    end.

%% Timeout, so it assumes that there's been a split vote
candidate(timeout, #state{} = State) ->
    start_election(State);

candidate(Msg, #state{node_id = Node, votes = Votes, log = Log,
                      addresses = Addresses, timeout = Timeout} = State) ->
    case Msg of
        {vote_response, true, Term} ->
            io:format("~p Accepted Vote from server~n", [Node]),
            if
                Votes > 1 ->
                    %% This is now the leader now
                    %% This timer must be a << election_timeout.
                    LastLogIndex = array:size(Log) - 1,
                    NextState = State#state{
                                  indexes = leader_index:new(Addresses, LastLogIndex)},
                    heartbeat(State),
                    {next_state, leader, NextState};
                true ->
                    {next_state, candidate,
                     State#state{votes = Votes + 1},
                     Timeout}
            end;
        {vote_response, false, Term} ->
            io:format("Rejected Vote~n"),
            io:format("Do something if term ~p is larger than my term~n", [Term]),
            {next_state, candidate, State, Timeout};
        follower ->
            io:format("Received AppendEntry from a valid leader.~n"),
            io:format("Stepping Down.~n"),
            {next_state, follower, State, Timeout};
        _Msg ->
            io:format("Unkown Message. Log it ~p~n", [Msg]),
            {next_state, candidate, State, Timeout}
    end.

%% Each server will vote only once. Need to persist to disk (TODO)

%% Raft has different timeouts. Each server has a different timeout, so they would start becoming a candidate at different times. [T, 2T]
%% see timeout_value/1
start_election(#state{term = CurrentTerm, node_id = Node, timeout = Timeout} = State) ->
    io:format("Node ~p just timed out. Starting election~n", [Node]),
    vote(State),
    {next_state, candidate, State#state{term = CurrentTerm + 1, voted_for = Node}, timeout = Timeout}.

terminate(_Reason, _LoopData) ->
    ok.

stop() ->
    gen_server:cast(?MODULE, stop).

handle_info(_I, StateName, State) ->
    {next_state, StateName, State}.

%% Useful debugging step for now. Checks the state of a node.
handle_event(status, StateName, #state{node_id = Node, timeout = Timeout} = StateData) ->
    io:format("node: ~p is running as ~p~n", [Node, StateName]),
    {next_state, StateName, StateData, Timeout}.

handle_sync_event(_Event, _From, StateName, StateData) ->
    {next_state, StateName, StateData}.

terminate(normal, _State, _Data) ->
    ok.

code_change(_OldVsn, State, LoopData, _Extra) ->
    {ok, State, LoopData}.

broadcast(Node, Addresses, Msg) ->
    OtherNodes = [A || A <- Addresses, A /= Node],
    lists:foreach(fun(N) -> gen_fsm:send_event({node, N}, Msg) end, OtherNodes).
