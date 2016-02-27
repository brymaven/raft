%%%---------------------------------------------------------------------
%%% Handles state changes
%%%---------------------------------------------------------------------

-module(node_state).

-include("raft_interface.hrl").
-export([new/2, follower_next_state/2, leader_next_state/2, next_state/2, leader_append_entry/2, timeout_value/1]).

new(Node, Addresses) ->
    EmptyLog = array:new({fixed, false}),

    %% TODO(bryant): Log must be persisted on disk.
    #state{log=array:set(0, #entry{term=0, command=initialize}, EmptyLog),
           node_id=Node, commit_index=0, addresses=Addresses,
           timeout=timeout_value(5000)}.

%% Random value between [T, 2T].
%% This allows progress eventually be made during leader elections.
timeout_value(T) ->
    random:seed(now()),
    T + random:uniform(T).

follower_next_state(#state{log=Log, commit_index=CommitIndex} = State,
                    #append_entry{leader_id=LeaderId, leader_commit=LeaderCommit,
                                  prev_term=PrevTerm, prev_index=PrevIndex,
                                  cur_term=CurTerm, cur_index=CurIndex,
                                  command=Command}) ->
    case (array:size(Log) > PrevIndex) andalso
        ((array:get(PrevIndex, Log))#entry.term == PrevTerm) of
        true ->
            NewEntry = #entry{term=CurTerm,
                              command=Command},
            ClearedLog = lists:foldl(fun (Idx, Arr) ->
                                             array:reset(Idx, Arr)
                                     end, Log,
                                     lists:seq(CurIndex, array:size(Log) - 1)),
            NewCommitIndex = if
                                 LeaderCommit > CommitIndex ->
                                     min(LeaderCommit, CurIndex);
                                 true ->
                                     CommitIndex
                             end,
            NewLog = case Command of
                         empty -> Log;
                         _     -> array:set(CurIndex, NewEntry, ClearedLog)
                     end,
            {NewLastApplied, NewMachine} =
                apply_command(State, (array:get(NewCommitIndex, NewLog))#entry.command,
                              NewCommitIndex),
            {true, State#state{log=NewLog, leader_id=LeaderId,
                               commit_index=NewCommitIndex,
                               machine=NewMachine, last_applied=NewLastApplied}};
        false -> {false, State}
    end.

-spec(leader_next_state(#state{}, #append_response{}) -> #state{}).
leader_next_state(#state{term=Term, indexes=LeaderIndex,
                         addresses=Addresses, log=Log,
                         commit_index=CommitIndex} = State,
                  #append_response{success=Success, node_id=NodeId}) ->
    L = length(Addresses),
    {LastLogIndex, _} = last_valid(Log),
    %% TODO(bryant): This obviously can be improved.
    %%               Once message gets to far, there's a success, but still shouldn't
    %%               increment next_index
    NewLeaderIndex = leader_index:update(NodeId, Success, LeaderIndex, LastLogIndex),
    Index = leader_index:next(NodeId, NewLeaderIndex) - 1,

    NewCommitIndex = case Success
                         andalso (leader_index:match(Index, NewLeaderIndex) > L/2)
                         andalso ((array:get(Index, Log))#entry.term == Term)
                         andalso (Index > CommitIndex) of
                         true  -> Index;
                         false -> CommitIndex
                     end,
    {NewLastApplied, NewMachine} = apply_command(State, (array:get(Index, Log))#entry.command, NewCommitIndex),

    State#state{indexes=NewLeaderIndex,
                commit_index=NewCommitIndex,
                last_applied=NewLastApplied,
                machine=NewMachine}.

apply_command(#state{last_applied=LastApplied, machine=Machine},
              Command, NewCommitIndex) ->
    if
        NewCommitIndex > LastApplied ->
            {_, NewMachine} = machine:apply(Command, Machine),
            {NewCommitIndex, NewMachine};
        true ->
            {LastApplied, Machine}
    end.

%% Create the append entry message for the next node
-spec(leader_append_entry(atom(), #state{}) -> #append_entry{}).
leader_append_entry(Node,
                    #state{term=Term, node_id=LeaderId, log=Log, indexes=LeaderIndices}) ->
    %% This is the lastest in the log
    %% Next index could never exceed LastLogIndex. It could only pos
    LastLogIndex = array:size(Log) - 1,
    NextIndex = leader_index:next(Node, LeaderIndices),
    PrevEntry = array:get(NextIndex - 1, Log),

    #append_entry{
       leader_id=LeaderId,
       cur_term=Term, cur_index=NextIndex,
       prev_term=PrevEntry#entry.term,
       prev_index=NextIndex - 1,
       command=case (NextIndex > LastLogIndex) of
                   true ->
                       empty;
                   false ->
                       (array:get(NextIndex, Log))#entry.command
               end}.

-spec(next_state(#request_vote{}, #state{}) -> {#vote_response{}, #state{}}).
next_state(#request_vote{
              term=Term, candidate_id=CandidateId,
              last_log_index=CandidateLogIndex, last_log_term=CandidateLogTerm},
           #state{node_id=Node, log=Log, term=CurrentTerm, voted_for=VotedFor} = State) ->
    VoteAtTerm = array:get(Term, VotedFor),
    io:format("Voted for ~p at term ~p~n", [VoteAtTerm, Term]),
    {LastLogIndex, #entry{term=LastLogTerm}} = last_valid(Log),
    if
        Term < CurrentTerm ->
            {#vote_response{term=CurrentTerm, vote_granted=false}, State};
        VoteAtTerm == undefined, CandidateLogTerm > LastLogTerm; (CandidateLogTerm == LastLogTerm) and (CandidateLogIndex >= LastLogIndex) ->
            io:format("Node: ~p voted for server ~p at term ~p~n", [Node, CandidateId, Term]),
            {#vote_response{term=CurrentTerm, vote_granted=true},
             State#state{
               voted_for=array:set(Term, CandidateId, VotedFor),
               leader_id=undefined}};
        true ->
            {#vote_response{term=CurrentTerm, vote_granted=false}, State}
    end.

%% TODO(bryant): Use a different data type for log than Array and remove this
last_valid(Array) ->
    array:sparse_foldl(fun (I, Element, Acc) ->
                              case Element of
                                  undefined ->
                                      Acc;
                                  _ -> {I, Element}
                              end
                      end, undefined, Array).
