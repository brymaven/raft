-module(node_state_tests).

-include("../src/raft_interface.hrl").
-include_lib("eunit/include/eunit.hrl").

append_entry_no_prev_index_test() ->
    ?assertMatch({false, _}, node_state:follower_next_state(
                               #state{log = array:new()},
                               #append_entry{prev_term=3, prev_index = 1})).

append_entry_prev_no_match_test() ->
    Log = array:from_list([#entry{term = 2}]),
    ?assertMatch({false, _}, node_state:follower_next_state(
                               #state{log = Log},
                               #append_entry{prev_term=3, prev_index = 0})).

append_entry_prev_match_test() ->
    Log = array:from_list([#entry{term = 1}, #entry{term = 2},
                           #entry{term = 3}, #entry{term = 4},
                           #entry{term = 5}]),
    {true, State} = node_state:follower_next_state(
                      #state{log = Log},
                      #append_entry{cur_index=2, cur_term=4, prev_term=1,
                                    prev_index = 0}),
    ?assertEqual(array:get(2, State#state.log), #entry{term=4}),
    ?assertEqual(array:get(3, State#state.log), undefined),
    ?assertEqual(array:get(4, State#state.log), undefined).

next_state_leader_test() ->
    LeaderIndexes = leader_index:new([a, b, c], 2),
    NewState = node_state:leader_next_state(#state{indexes = LeaderIndexes},
                                            #append_response{node_id=a, success=true}),
    ?assertEqual({ok, {1, 4}}, dict:find(a, NewState#state.indexes)).
