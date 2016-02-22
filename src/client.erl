%%%---------------------------------------------------------------------
%%% Raft Client
%%%---------------------------------------------------------------------

-module(client).
-export([get/1, delete/1, put/2, leader/0]).

%% TODO(bryant): Just looks at first node right now. Just need to do this once
%% and then pass along the leader
leader() ->
    {ok, [Address | _Addresses]} = application:get_env(raft, addresses),
    try gen_fsm:sync_send_all_state_event({node, Address}, leader, 5000) of
        undefined ->
            {error, no_leader_elected};
        Leader -> {ok, Leader}
    catch
        exit:_Exit ->
            {error, node_not_running}
    end.

get(Key) ->
    execute({get, Key}).

delete(Key) ->
    execute({delete, Key}).

put(Key, Value) ->
    execute({put, Key, Value}).

execute(Msg) ->
    case leader() of
        {ok, Leader} ->
            gen_fsm:sync_send_event({node, Leader}, Msg, 5000);
        Error ->
            Error
    end.
