-module(raft_app).
-export([start/2, stop/1]).
-behaviour(application).

start(_StartType, _Args) ->
    {ok, Addresses} = application:get_env(addresses),
    super:start_link(Addresses).

stop(_State) ->
    ok.
