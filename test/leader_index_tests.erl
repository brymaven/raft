-module(leader_index_tests).
-include_lib("eunit/include/eunit.hrl").

%% TODO(bryant): Use quickcheck instead of this fixture
indexes() ->
    leader_index:new([a, b, c], 2).

new_indexes_test() ->
    Indexes = indexes(),
    ?assertEqual({ok, {0, 3}}, dict:find(a, Indexes)),
    ?assertEqual({ok, {0, 3}}, dict:find(b, Indexes)),
    ?assertEqual({ok, {0, 3}}, dict:find(c, Indexes)).

update_indexes_test() ->
    [fun success_increments_index/0,
     fun success_decrements_index/0].

success_increments_index() ->
    Indexes = indexes(),
    Indexes2 = leader_index:update(a, true, Indexes),
    ?assertEqual({ok, {1, 4}}, dict:find(a, Indexes2)).

success_decrements_index() ->
    Indexes = indexes(),
    Indexes2 = leader_index:update(a, false, Indexes),
    ?assertEqual({ok, {0, 2}}, dict:find(a, Indexes2)).
