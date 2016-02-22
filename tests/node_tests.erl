-module(node_tests).
-include("raft_interface.hrl").
-include_lib("eunit/include/eunit.hrl").

%% candidate_vote_response_test() ->
%%     {next_state,StateName,#state{volatile = Volatile}} = node:candidate({vote_response, 0, true}, #state{volatile = #volatile{votes=3}}),
%%     ?assertEqual(StateName,leader),
%%     ?assertEqual(Volatile, #volatile{votes=3}).

%% candidate_vote_reject_response_test() ->
%%     ?assertMatch({next_state,candidate,_State,_Timeout}, node:candidate({vote_response, 0, false}, #state{})).

%% initial_request_vote_sends_init_entry_test() ->
%%     node:vote(#state{log=array:new({fixed, false})}),
%%     ?assertEqual(2, 2).

%% follower_vote_response_test() ->
%%     node:follower({vote, nobody, #request_vote{term=0, candidate_id=nobody}},
%%                   #state{term = 1}).


append_entry_has_cur_index_test() ->
    Log0 = array:new({fixed, false}),
    Log =  array:set(0, a, Log0),
    LogSize = array:size(Log),
    Combined = case (LogSize >= 1) and (array:get(5, Log) == a) andalso ((array:get(5, Log))#entry.term == c) of
        true -> a;
        false -> b
    end,
    io:format("The log has ~p elements. Condition ~p. ~n", [LogSize, Combined]).

%% Good tests

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
