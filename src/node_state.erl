%%%---------------------------------------------------------------------
%%% Handles state changes
%%%---------------------------------------------------------------------

-module(node_state).

-include("raft_interface.hrl").
-export([new/2, follower_next_state/2, leader_next_state/2, next_state/2]).

new(Node, Addresses) ->
    EmptyLog = array:new({fixed, false}),

    %% TODO(bryant): Log must be persisted on disk.
    #state{log=array:set(0, #entry{term=0, command=initialize}, EmptyLog),
           node_id=Node, commit_index=0, addresses=Addresses,
           timeout=timeout_value(5000)}.

%% Random value between [T, 2T].
%% This allows progress eventually be made during leader elections.
timeout_value(T) ->
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
            {true, State#state{log=array:set(CurIndex, NewEntry, ClearedLog),
                               leader_id=LeaderId, commit_index=NewCommitIndex}};
        false -> {false, State}
    end.

-spec(leader_next_state(#state{}, #append_response{}) -> #state{}).
leader_next_state(#state{term=Term, indexes=LeaderIndex,
                         addresses=Addresses, log=Log,
                         commit_index=CommitIndex} = State,
                  #append_response{success=Success, node_id=NodeId}) ->
    L = length(Addresses),
    NewLeaderIndex = leader_index:update(NodeId, Success, LeaderIndex),
    Index = leader_index:next(NodeId, NewLeaderIndex) - 1,

    NewCommitIndex = case (leader_index:match(Index, NewLeaderIndex) > L/2)
                         and ((array:get(Index, Log))#entry.term == Term)
                         and (Index > CommitIndex) of
                         true  -> Index;
                         false -> CommitIndex
                     end,
    State#state{indexes=leader_index:update(NodeId, Success, LeaderIndex),
                commit_index=NewCommitIndex}.

-spec(next_state(#request_vote{}, #state{}) -> {#vote_response{}, #state{}}).
next_state(#request_vote{
              term=Term, candidate_id=CandidateId,
              last_log_index=CandidateLogIndex, last_log_term=CandidateLogTerm},
           #state{node_id=Node, log=Log, term=CurrentTerm, voted_for=VotedFor} = State) ->
    VoteAtTerm = array:get(Term, VotedFor),
    {LastLogIndex, #entry{term=LastLogTerm}} = last_valid(Log),
    if
        Term < CurrentTerm ->
            {#vote_response{term=CurrentTerm, vote_granted=false}, State};
        VoteAtTerm == undefined, CandidateLogTerm > LastLogTerm; (CandidateLogTerm == LastLogTerm) and (CandidateLogIndex >= LastLogIndex) ->
            io:format("Node: ~p voted for server at term ~p~n", [Node, Term]),
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
