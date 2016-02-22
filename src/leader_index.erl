%%%---------------------------------------------------------------------
%%% Volatile state used by leader to track next log entry to send
%%%---------------------------------------------------------------------

-module(leader_index).
-export([new/2, update/3]).

-spec(new(list(), integer()) -> dict:dict()).
new(Addresses, LastLogIndex) ->
    lists:foldl(fun(Address, Dict) ->
                        dict:store(Address, {0, LastLogIndex + 1}, Dict)
                end, dict:new(), Addresses).

-spec(update(atom(), boolean(), dict:dict()) -> dict:dict()).
update(Node, Success, Dict) ->
    dict:update(Node,
                fun({MatchIndex, NextIndex}) ->
                        case Success of
                            true -> {MatchIndex + 1, NextIndex + 1};
                            _ -> {MatchIndex, NextIndex - 1}
                        end
                end, Dict).
