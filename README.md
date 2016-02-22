# Raft
#######
Partial implementation of Raft.

## Quickstart
* Update the ``conf/raft.config`` to use your hostname. Note that this should be fully qualified.
````erlang
  'node0@your-host'
  %% You can even use multiple hosts
  'node1@another-host'
````
  * If you don't know your hostname, one way to find out on OS X is by executing the following command.
````bash
$ host `hostname`
````
* Open some tabs(3+) and start the nodes. On each tab, start a node with the following command. The node name should correspond to what you included in your ``raft.config`` file.
````sh
$ bin/raft add node0
````
