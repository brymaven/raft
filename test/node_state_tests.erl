-module(node_state_tests).

-include("../src/raft_interface.hrl").
-include_lib("eunit/include/eunit.hrl").

append_entry_no_prev_index_test() ->
    ?assertMatch({false, _}, node_state:follower_next_state(
                               #state{log=array:new()},
                               #append_entry{prev_term=3, prev_index=1})).

append_entry_prev_no_match_test() ->
    Log = array:from_list([#entry{term=2}]),
    ?assertMatch({false, _}, node_state:follower_next_state(
                               #state{log=Log},
                               #append_entry{prev_term=3, prev_index=0})).

append_entry_prev_match_test() ->
    Log = array:from_list([#entry{term=1}, #entry{term=2},
                           #entry{term=3}, #entry{term=4},
                           #entry{term=5}]),
    {true, State} = node_state:follower_next_state(
                      #state{log = Log},
                      #append_entry{cur_index=2, cur_term=4, prev_term=1,
                                    prev_index = 0}),
    ?assertEqual(array:get(2, State#state.log), #entry{term=4}),
    ?assertEqual(array:get(3, State#state.log), undefined),
    ?assertEqual(array:get(4, State#state.log), undefined).

follower_commit_index_test() ->
    [fun follower_uses_last_commit_index/0,
     fun follower_uses_leader_commit_index/0,
     fun follower_keeps_commit_index/0].

follower_uses_last_commit_index() ->
    Log = array:from_list([#entry{term=1}, #entry{term=2}]),
    {true, State} = node_state:follower_next_state(
                      #state{log = Log, commit_index=0},
                      #append_entry{cur_index=2, cur_term=4,
                                    prev_term=1, prev_index=0,
                                    leader_commit=1}),
    ?assertEqual(2, State#state.commit_index).

follower_uses_leader_commit_index() ->
    Log = array:from_list([#entry{term=1}, #entry{term=2}]),
    {true, State} = node_state:follower_next_state(
                      #state{log = Log, commit_index=0},
                      #append_entry{cur_index=2, cur_term=4,
                                    prev_term=1, prev_index=0,
                                    leader_commit=5}),
    ?assertEqual(5, State#state.commit_index).

follower_keeps_commit_index() ->
    Log = array:from_list([#entry{term=1}, #entry{term=2}]),
    {true, State} = node_state:follower_next_state(
                      #state{log = Log, commit_index=3},
                      #append_entry{cur_index=2, cur_term=4,
                                    prev_term=1, prev_index=0,
                                    leader_commit=1}),
    ?assertEqual(3, State#state.commit_index).

next_state_leader_test_() ->
    [initial_log(),
     all_commit_conditions(),
     non_majority_match_commit_conditions(),
     different_log_term_commit_conditions(),
     lower_index_commit_conditions()].

initial_log() ->
    LeaderIndexes = leader_index:new([a, b, c], 0),

    NewState = node_state:leader_next_state(
                 #state{indexes=LeaderIndexes,
                        addresses=[a,b,c],
                        term=1,
                        log=array:from_list([#entry{term=1}])},
                 #append_response{node_id=a, success=true}),
    ?_assertEqual(0, NewState#state.commit_index).

all_commit_conditions() ->
    LeaderIndexes = leader_index:new([a, b, c], 0),
    LeaderIndexes2 = leader_index:update(b, true, LeaderIndexes),
    NewState = node_state:leader_next_state(
                 #state{indexes=LeaderIndexes2,
                        addresses=[a,b,c],
                        term=1,
                        log=array:from_list([#entry{term=1}, #entry{term=1}])},
                 #append_response{node_id=a, success=true}),
    ?_assertEqual(1, NewState#state.commit_index).

non_majority_match_commit_conditions() ->
    LeaderIndexes = leader_index:new([a, b, c], 0),
    NewState = node_state:leader_next_state(
                 #state{indexes=LeaderIndexes,
                        addresses=[a,b,c],
                        term=1,
                        log=array:from_list([#entry{term=1}, #entry{term=1}])},
                 #append_response{node_id=a, success=true}),
    ?_assertEqual(0, NewState#state.commit_index).

different_log_term_commit_conditions() ->
    LeaderIndexes = leader_index:new([a, b, c], 0),
    LeaderIndexes2 = leader_index:update(b, true, LeaderIndexes),
    NewState = node_state:leader_next_state(
                 #state{indexes=LeaderIndexes2,
                        addresses=[a,b,c],
                        term=2,
                        log=array:from_list([#entry{term=1}, #entry{term=1}])},
                 #append_response{node_id=a, success=true}),
    ?_assertEqual(0, NewState#state.commit_index).

lower_index_commit_conditions() ->
    LeaderIndexes = leader_index:new([a, b, c], 0),
    LeaderIndexes2 = leader_index:update(b, true, LeaderIndexes),
    NewState = node_state:leader_next_state(
                 #state{indexes=LeaderIndexes2,
                        addresses=[a,b,c],
                        term=1,
                        commit_index=3,
                        log=array:from_list([#entry{term=1}, #entry{term=1}])},
                 #append_response{node_id=a, success=true}),
    ?_assertEqual(3, NewState#state.commit_index).

next_state_test_() ->
    [terms_equal_candidate_larger_log(),
     terms_equal_candidate_smaller_log(),
     terms_equal_candidate_equal_log_index(),
     candidate_term_smaller()].

terms_equal_candidate_larger_log() ->
    RequestVote = #request_vote{term=2, last_log_index=2, last_log_term=2},
    Log = array:from_list([#entry{term=2}]),

    ?_assertMatch({#vote_response{vote_granted=true}, _State}, node_state:next_state(RequestVote, #state{log=Log})).

terms_equal_candidate_smaller_log() ->
    RequestVote = #request_vote{term=2, last_log_index=2, last_log_term=2},
    Log = array:from_list([#entry{term=2}, #entry{term=2},
                           #entry{term=2}, #entry{term=2}]),

    ?_assertMatch({#vote_response{vote_granted=false}, _State}, node_state:next_state(RequestVote, #state{log=Log})).

terms_equal_candidate_equal_log_index() ->
    RequestVote = #request_vote{term=2, last_log_index=2, last_log_term=2},
    Log = array:from_list([#entry{term=2}, #entry{term=2}, #entry{term=2}]),

    ?_assertMatch({#vote_response{vote_granted=true}, _State}, node_state:next_state(RequestVote, #state{log=Log})).

candidate_term_smaller() ->
    RequestVote = #request_vote{term=2, last_log_index=5, last_log_term=1},
    Log = array:from_list([#entry{term=2}, #entry{term=2}, #entry{term=2}]),

    ?_assertMatch({#vote_response{vote_granted=false}, _State}, node_state:next_state(RequestVote, #state{log=Log})).


leader_append_entry_test_() ->
    [append_entry_heartbeat(),
     append_entry_first_entry(),
     append_entry_second_entry(),
     append_entry_out_of_bound()].

leader_state() ->
    Addresses = [a,b,c],
    LeaderIndices = leader_index:new(Addresses, 0),
    (node_state:new(b, Addresses))
        #state{indexes=LeaderIndices,
               term=4}.

append_entry_heartbeat() ->
    State = leader_state(),
    AppendEntry = node_state:leader_append_entry(a, State),
    ?_assertMatch(#append_entry{prev_term=0, prev_index=0,
                                cur_term=4, cur_index=1,
                                command=empty}, AppendEntry).

append_entry_first_entry() ->
    Log = array:from_list(
            [#entry{term=0, command=initialized},
             #entry{term=1, command={put, 3, a}}]),

    State = (leader_state())#state{log=Log},
    AppendEntry = node_state:leader_append_entry(a, State),
    ?_assertMatch(#append_entry{prev_term=0,
                                prev_index=0,
                                cur_term=4,
                                command={put,3,a}}, AppendEntry).

append_entry_second_entry() ->
    Log = array:from_list(
            [#entry{term=0, command=initialized},
             #entry{term=1, command={put, 3, a}},
             #entry{term=1, command={put, 3, b}}]),

    Addresses = [a,b,c],
    LeaderIndices = leader_index:update(
                      a, true,
                      leader_index:new(Addresses, 0)),
    State = (node_state:new(b, Addresses))
        #state{indexes=LeaderIndices,
               term=4,
               log=Log},
    AppendEntry = node_state:leader_append_entry(a, State),
    ?_assertMatch(#append_entry{prev_term=1,
                                prev_index=1,
                                cur_term=4,
                                cur_index=2,
                                command={put,3,b}}, AppendEntry).

append_entry_out_of_bound() ->
    Log = array:from_list(
            [#entry{term=0, command=initialized},
             #entry{term=1, command={put, 3, a}}]),

    Addresses = [a,b,c],
    LeaderIndices = leader_index:update(
                      a, true,
                      leader_index:new(Addresses, 0)),
    State = (node_state:new(b, Addresses))
        #state{indexes=LeaderIndices,
               term=4,
               log=Log},
    AppendEntry = node_state:leader_append_entry(a, State),
    io:format("AppendEntry Entry command ~p~n", [AppendEntry#append_entry.command]),
    ?_assertMatch(#append_entry{prev_term=1,
                                prev_index=1,
                                cur_term=4,
                                cur_index=2,
                                command=empty}, AppendEntry).
