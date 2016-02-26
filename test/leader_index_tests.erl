-module(leader_index_tests).
-include_lib("eunit/include/eunit.hrl").

%% TODO(bryant): Use quickcheck instead of this fixture
indexes() ->
    leader_index:new([a, b, c], 2).

new_indexes_test() ->
    Indexes = indexes(),
    ?assertEqual(3, leader_index:next(a, Indexes)),
    ?assertEqual(3, leader_index:next(b, Indexes)),
    ?assertEqual(3, leader_index:next(c, Indexes)).

update_indexes_test_() ->
    [fun success_increments_index/0,
     fun success_decrements_index/0,
     fun success_does_not_increment_at_end/0].

success_increments_index() ->
    Indexes = indexes(),
    Indexes2 = leader_index:update(a, true, Indexes, 4),
    ?assertEqual(4, leader_index:next(a, Indexes2)),
    ?assertEqual(1, leader_index:match(3, Indexes2)).

success_does_not_increment_at_end() ->
    Indexes = indexes(),
    Indexes2 = leader_index:update(a, true, Indexes, 2),
    ?assertEqual(3, leader_index:next(a, Indexes2)),
    ?assertEqual(1, leader_index:match(3, Indexes2)).

success_decrements_index() ->
    Indexes = indexes(),
    Indexes2 = leader_index:update(a, false, Indexes, 4),
    ?assertEqual(2, leader_index:next(a, Indexes2)),
    ?assertEqual(0, leader_index:match(3, Indexes2)).
