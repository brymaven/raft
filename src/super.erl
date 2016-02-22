-module(super).
-behaviour(supervisor).

-export([start_link/1]).
-export([init/1, stop/0]).
-export([add_node/2, remove_node/1, list_nodes/0]).
-export([restart_app/0]).

%% Child specifications
start_link(Addresses) ->
    Node = node(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, {Node, Addresses}).

%% Starts initial node
%% See add_node to add the rest
init({NodeId, Addresses}) ->
    %% TODO(bryant): Pass a tracer, log. Cool that I can specify multiple processes
    NodeSpec = {node, {node, start_link, [NodeId, Addresses]},
                transient, 200,
                worker,
                [node]},
    {ok, {{one_for_one, 1, 1}, [NodeSpec]}}.

%% supervisor does not export a ``stop`` function. Supervisors are never meant to be
%% stopped by anyone other than their parent supervisors
stop() ->
    exit(whereis(?MODULE), shutdown).

%% Testing
%% exit(whereis(node), kill).
node_spec(NodeId, Addresses) ->
    {NodeId, {node, start_link, [NodeId, Addresses]},
     transient, 200,
     worker,
     [node]}.

add_node(NodeId, Addresses) ->
    supervisor:start_child(?MODULE, node_spec(NodeId, Addresses)).

remove_node(Node) ->
    supervisor:terminate_child(?MODULE, Node).

%% TODO(bryant): Useful for Debugging. Remove this once I have more solid cold
list_nodes() ->
    NodeIds = lists:map(fun({Id, _, _, _}) -> Id end,
                        supervisor:which_children(?MODULE)),
    lists:foreach(fun(N) -> gen_fsm:send_all_state_event(N, status) end, NodeIds).

%% TODO(bryant): Remove this, just restarts the application.
restart_app() ->
    Addresses = [node0, node1, node2, node3, node],
    application:stop(raft),
    application:start(raft),
    receive
        _ -> nothing
    after
        2000 ->
            add_node(node1, Addresses),
            add_node(node2, Addresses),
            add_node(node3, Addresses)
    end.
