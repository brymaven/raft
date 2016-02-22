%%%---------------------------------------------------------------------
%%% State Machine for Raft (Currently just abstraction over dict)
%%%---------------------------------------------------------------------
-module(machine).
-export([new/0, apply/3, apply/4]).

-spec(new() -> dict:dict()).
new() ->
    dict:new().

-spec(apply(atom(), term(), dict:dict()) -> dict:dict()).
apply(delete, Key, Dict) ->
    dict:erase(Key, Dict);

apply(get, Key, Dict) ->
    dict:find(Key, Dict).

-spec(apply(atom(), term(), term(), dict:dict()) -> dict:dict()).
apply(put, Key, Value, Dict) ->
    dict:store(Key, Value, Dict).
