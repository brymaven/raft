%%%---------------------------------------------------------------------
%%% Handles state changes
%%%---------------------------------------------------------------------

-module(node_state).

-include("raft_interface.hrl").
-export([new/2, follower_next_state/2, leader_next_state/2]).

new(Node, Addresses) ->
    EmptyLog = array:new({fixed, false}),

    %% TODO(bryant): Log must be persisted on disk.
    #state{log=array:set(0, #entry{term=0, command=initialize}, EmptyLog),
           node_id=Node, addresses=Addresses, timeout=timeout_value(10000)}.

%% Random value between [T, 2T].
%% This allows progress eventually be made during leader elections.
timeout_value(T) ->
    T + random:uniform(T).

follower_next_state(#state{log=Log} = State,
                    #append_entry{leader_id=LeaderId, command=Command,
                                  prev_term=PrevTerm, prev_index=PrevIndex,
                                  cur_term=CurTerm, cur_index=CurIndex}) ->
    case (array:size(Log) > PrevIndex) andalso
        ((array:get(PrevIndex, Log))#entry.term == PrevTerm) of
        true ->
            NewEntry = #entry{term=CurTerm,
                              command=Command},
            ClearedLog = lists:foldl(fun (Idx, Arr) ->
                                             array:reset(Idx, Arr)
                                     end, Log,
                                     lists:seq(CurIndex, array:size(Log) - 1)),
            {true, State#state{log=array:set(CurIndex, NewEntry, ClearedLog),
                               leader_id = LeaderId}};
        false -> {false, State}
    end.

-spec(leader_next_state(#state{}, #append_response{}) -> #state{}).
leader_next_state(#state{indexes=LeaderIndex} = State,
                  #append_response{success=Success, node_id=NodeId}) ->
    State#state{indexes=leader_index:update(NodeId, Success, LeaderIndex)}.
