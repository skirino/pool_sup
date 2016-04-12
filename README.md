# PoolSup: Yet another process pool library in [Elixir](http://elixir-lang.org/)

`PoolSup` defines a supervisor which is specialized to manage pool of worker processes.
- [API Documentation](http://hexdocs.pm/pool_sup/)
- [Hex package information](https://hex.pm/packages/pool_sup)

[![Hex.pm](http://img.shields.io/hexpm/v/pool_sup.svg)](https://hex.pm/packages/pool_sup)
[![Build Status](https://travis-ci.org/skirino/pool_sup.svg)](https://travis-ci.org/skirino/pool_sup)
[![Coverage Status](https://coveralls.io/repos/github/skirino/pool_sup/badge.svg?branch=master)](https://coveralls.io/github/skirino/pool_sup?branch=master)

## Features

- Process defined by this module behaves as a `:simple_one_for_one` supervisor.
- Worker processes are spawned using a callback module that implements `PoolSup.Worker` behaviour.
- `PoolSup` process manages which worker processes are in use and which are not.
- `PoolSup` automatically restart crashed workers.
- Functions to request pid of an available worker process: `checkout/2`, `checkout_nonblocking/2`.
- Run-time configuration of pool size: `change_capacity/3`.
- Load-balancing using multiple pools: `PoolSup.Multi`.

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

    iex(2)> {:ok, pool_sup_pid} = PoolSup.start_link(MyWorker, {:worker, :arg}, 3, 0, [name: :my_pool])

Each worker process is started using `MyWorker.start_link({:worker, :arg})`.
Then we can get a pid of a child currently not in use:

    iex(3)> worker_pid = PoolSup.checkout(:my_pool)
    iex(4)> do_something(worker_pid)
    iex(5)> PoolSup.checkin(:my_pool, worker_pid)

Don't forget to return the `worker_pid` when finished; for simple use cases `PoolSup.transaction/3` comes in handy.

## Reserved and on-demand worker processes

`PoolSup` defines the following two parameters to control capacity of a pool:

- `reserved` (3rd argument of `start_link/5`): Number of workers to keep alive.
- `ondemand` (4th argument of `start_link/5`): Maximum number of workers that are spawned on-demand.

In short:

    {:ok, pool_sup_pid} = PoolSup.start_link(MyWorker, {:worker, :arg}, 2, 1)
    w1  = PoolSup.checkout_nonblocking(pool_sup_pid) # => pre-spawned worker pid
    w2  = PoolSup.checkout_nonblocking(pool_sup_pid) # => pre-spawned worker pid
    w3  = PoolSup.checkout_nonblocking(pool_sup_pid) # => newly-spawned worker pid
    nil = PoolSup.checkout_nonblocking(pool_sup_pid)
    PoolSup.checkin(pool_sup_pid, w1)                # `w1` is terminated
    PoolSup.checkin(pool_sup_pid, w2)                # `w2` is kept alive for the subsequent checkout
    PoolSup.checkin(pool_sup_pid, w3)                # `w3` is kept alive for the subsequent checkout

## Usage within supervision tree

The following code snippet spawns a supervisor that has `PoolSup` process as one of its children:

    chilldren = [
      ...
      Supervisor.Spec.supervisor(PoolSup, [MyWorker, {:worker, :arg}, 5, 3]),
      ...
    ]
    Supervisor.start_link(children, [strategy: :one_for_one])

The `PoolSup` process initially has 5 workers and can temporarily have up to 8.
All workers are started by `MyWorker.start_link({:worker, :arg})`.

You can of course define a wrapper function of `PoolSup.start_link/4` and use it in your supervisor spec.
