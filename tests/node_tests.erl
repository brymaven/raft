-module(node_tests).
-include("raft_interface.hrl").
-include_lib("eunit/include/eunit.hrl").

append_entry_no_prev_index_test() ->
    ?assertMatch({false, _}, node:follower_next_state(
                               #state{log = array:new()},
                               #append_entry{prev_term=3, prev_index = 1})).

append_entry_prev_no_match_test() ->
    Log = array:from_list([#entry{term = 2}]),
    ?assertMatch({false, _}, node:follower_next_state(
                               #state{log = Log},
                               #append_entry{prev_term=3, prev_index = 0})).

append_entry_prev_match_test() ->
    Log = array:from_list([#entry{term = 3}]),
    {true, State} = node:follower_next_state(
                      #state{log = Log},
                      #append_entry{cur_index=2, cur_term=4, prev_term=3,
                                    prev_index = 0}),
    ?assertEqual(array:get(2, State#state.log), #entry{term=4}).
