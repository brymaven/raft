-module(machine_test).
-include_lib("eunit/include/eunit.hrl").

machine_fixture() ->
    Machine = machine:new(),
    dict:store(a, 1, Machine).

get_test() ->
    ?assertEqual({ok, 1}, machine:apply(get, a, machine_fixture())).

delete_test() ->
    Machine = machine:apply(delete, a, machine_fixture()),
    ?assertEqual(error, machine:apply(get, a, Machine)).

put_test() ->
    Machine = machine:apply(put, b, 2, machine_fixture()),
    ?assertEqual({ok, 1}, machine:apply(get, a, Machine)),
    ?assertEqual({ok, 2}, machine:apply(get, b, Machine)).
