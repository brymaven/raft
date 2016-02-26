%%%---------------------------------------------------------------------
%%% Volatile state used by leader to track next log entry to send
%%%---------------------------------------------------------------------

-module(leader_index).
-export([new/2, match/2, update/3, next/2]).
-record(leader_index, {next_index, match_index, n}).

-spec(new(list(), integer()) -> dict:dict()).
new(Addresses, LastLogIndex) ->
    NextIndex = lists:foldl(fun(Address, Dict) ->
                                    dict:store(Address, LastLogIndex + 1, Dict)
                            end, dict:new(), Addresses),
    MatchIndex = array:new([{fixed, false}, {default, 0}]),
    #leader_index{next_index=NextIndex, match_index=MatchIndex, n=length(Addresses)}.

-spec(update(atom(), boolean(), #leader_index{}) -> #leader_index{}).
update(Node, Success,
       #leader_index{next_index=NextIndices, match_index=MatchIndices} = LeaderIndex) ->
    NextIndex = next(Node, LeaderIndex),

    {NewMatchIndices, NewNextIndices} =
        case Success of
            true ->
                {increment(NextIndex, MatchIndices),
                 dict:store(Node, NextIndex + 1, NextIndices)};
            false ->
                {MatchIndices,
                 dict:store(Node, NextIndex - 1, NextIndices)}
    end,
    LeaderIndex#leader_index{next_index=NewNextIndices, match_index=NewMatchIndices}.

%% Safe operation
-spec(next(atom(), #leader_index{}) -> integer()).
next(Node, #leader_index{next_index=NextIndices}) ->
    {ok, Index} = dict:find(Node, NextIndices),
    Index.

%% Safe operation
match(I, #leader_index{match_index=MatchIndices}) ->
    array:get(I, MatchIndices).

increment(I, Array) ->
    case array:get(I, Array) of
        undefined ->
            array:set(I, 1, Array);
        Count ->
            array:set(I, Count + 1, Array)
    end.
