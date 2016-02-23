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

next_state_leader_test() ->
    LeaderIndexes = leader_index:new([a, b, c], 2),
    NewState = node_state:leader_next_state(#state{indexes=LeaderIndexes},
                                            #append_response{node_id=a, success=true}),
    ?assertEqual({ok, {1, 4}}, dict:find(a, NewState#state.indexes)).

next_state_test_() ->
    [terms_equal_candidate_larger_log(),
     terms_equal_candidate_smaller_log(),
     terms_equal_candidate_equal_log_index(),
     candidate_term_smaller()].

terms_equal_candidate_larger_log() ->
    RequestVote = #request_vote{term=2, last_log_index=2, last_log_term=2},
    Log = array:from_list([#entry{term=2}]),

    ?_assertMatch({true, _State}, node_state:next_state(RequestVote, #state{log=Log})).

terms_equal_candidate_smaller_log() ->
    RequestVote = #request_vote{term=2, last_log_index=2, last_log_term=2},
    Log = array:from_list([#entry{term=2}, #entry{term=2},
                           #entry{term=2}, #entry{term=2}]),

    ?_assertMatch({false, _State}, node_state:next_state(RequestVote, #state{log=Log})).

terms_equal_candidate_equal_log_index() ->
    RequestVote = #request_vote{term=2, last_log_index=2, last_log_term=2},
    Log = array:from_list([#entry{term=2}, #entry{term=2}, #entry{term=2}]),

    ?_assertMatch({true, _State}, node_state:next_state(RequestVote, #state{log=Log})).

candidate_term_smaller() ->
    RequestVote = #request_vote{term=2, last_log_index=5, last_log_term=1},
    Log = array:from_list([#entry{term=2}, #entry{term=2}, #entry{term=2}]),

    ?_assertMatch({false, _State}, node_state:next_state(RequestVote, #state{log=Log})).
