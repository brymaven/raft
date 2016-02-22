-module(raft_app).

-behaviour(application).

%% ===================================================================
%% Application callbacks
%% ===================================================================
-export([start/2, stop/1]).

start(_StartType, _Args) ->
    {ok, Addresses} = application:get_env(addresses),
    super:start_link(Addresses).

stop(_State) ->
    ok.
