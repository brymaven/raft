{application,raft,
 [{description, "RAFT consensus protocol"},
  {vsn, "1.0"},
  {modules,[node, super]},
  {registered,[node, super]},
  {applications, [kernel,stdlib]},
  {env, []},
  {mod,{raft_app,[]}}]}.
