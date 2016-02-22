-module(super).
-behaviour(supervisor).

-export([start_link/1, init/1, stop/0]).

start_link(Addresses) ->
    Node = node(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, {Node, Addresses}).

init({NodeId, Addresses}) ->
    %% TODO(bryant): Pass a tracer, log. Cool that I can specify multiple processes
    NodeSpec = {node, {node, start_link, [NodeId, Addresses]},
                transient, 200,
                worker,
                [node]},
    {ok, {{one_for_one, 1, 1}, [NodeSpec]}}.

stop() ->
    exit(whereis(?MODULE), shutdown).
