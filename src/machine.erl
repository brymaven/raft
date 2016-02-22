%%%---------------------------------------------------------------------
%%% State Machine for Raft (Currently just abstraction over dict)
%%%---------------------------------------------------------------------
-module(machine).
-export([new/0, apply/2]).

-spec(new() -> dict:dict()).
new() ->
    dict:new().

-spec(apply(term(), dict:dict()) -> {ok | term() | empty, dict:dict()}).
apply(Msg, Dict) ->
    case Msg of
        {get, Key} ->
            Value = dict:find(Key, Dict),
            {Value, Dict};
        {delete, Key} ->
            {ok, dict:erase(Key, Dict)};
        {put, Key, Value} ->
            {ok, dict:store(Key, Value, Dict)};
        _ ->
            {undefined_op, Dict}
    end.
