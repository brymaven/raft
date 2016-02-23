-module(machine_tests).
-include_lib("eunit/include/eunit.hrl").

machine_fixture() ->
    Machine = machine:new(),
    dict:store(a, 1, Machine).

get_test() ->
    ?assertMatch({{ok, 1}, _}, machine:apply({get, a}, machine_fixture())).

delete_test() ->
    {ok, Machine} = machine:apply({delete, a}, machine_fixture()),
    ?assertMatch({error, _}, machine:apply({get, a}, Machine)).

put_test() ->
    {ok, Machine} = machine:apply({put, b, 2}, machine_fixture()),
    ?assertMatch({{ok, 1}, _}, machine:apply({get, a}, Machine)),
    ?assertMatch({{ok, 2}, _}, machine:apply({get, b}, Machine)).
