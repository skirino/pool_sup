# PoolSup: Yet another process pool library in [Elixir](http://elixir-lang.org/)

`PoolSup` defines a supervisor which is specialized to manage pool of worker processes.
- [API Documentation](http://hexdocs.pm/pool_sup/)
- [Hex package information](https://hex.pm/packages/pool_sup)

[![Hex.pm](http://img.shields.io/hexpm/v/pool_sup.svg)](https://hex.pm/packages/pool_sup)
[![Build Status](https://travis-ci.org/skirino/pool_sup.svg)](https://travis-ci.org/skirino/pool_sup)
[![Coverage Status](https://coveralls.io/repos/github/skirino/pool_sup/badge.svg?branch=master)](https://coveralls.io/github/skirino/pool_sup?branch=master)

## Example

Suppose we have a module that implements both `GenServer` and `PoolSup.Worker` behaviours
(`PoolSup.Worker` behaviour requires only 1 callback to implement, `start_link/1`).

    iex(1)> defmodule MyWorker do
    ...(1)>   @behaviour PoolSup.Worker
    ...(1)>   use GenServer
    ...(1)>   def start_link(arg) do
    ...(1)>     GenServer.start_link(__MODULE__, arg)
    ...(1)>   end
    ...(1)>   # definitions of gen_server callbacks...
    ...(1)> end

When we want to have 3 worker processes that run `MyWorker` server:

    iex(2)> {:ok, pool_sup_pid} = PoolSup.start_link(MyWorker, {:worker, :arg}, 3, [name: :my_pool])

Each worker process is started using `MyWorker.start_link({:worker, :arg})`.
Then we can get a pid of a child currently not in use:

    iex(3)> child_pid = PoolSup.checkout(:my_pool)
    iex(4)> do_something(child_pid)
    iex(5)> PoolSup.checkin(:my_pool, child_pid)

Don't forget to return the `child_pid` when finished; for simple use cases `PoolSup.transaction/3` comes in handy.

### Usage within supervision tree

The following code snippet spawns a supervisor that has `PoolSup` process as one of its children.
The `PoolSup` process manages 5 worker processes and they will be started by `MyWorker.start_link({:worker, :arg})`.

    chilldren = [
      ...
      Supervisor.Spec.supervisor(PoolSup, [MyWorker, {:worker, :arg}, 5]),
      ...
    ]
    Supervisor.start_link(children, [strategy: :one_for_one])

You can of course define a wrapper function of `PoolSup.start_link/4` and use it in your supervisor spec.
