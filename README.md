# Replayx

> **Deterministic replay debugging for Elixir processes. Reproduce crashes. Kill Heisenbugs. Sleep better.**

Replayx lets you **record** everything that makes a GenServer nondeterministic (messages, time, randomness) and **replay** it later so the same crash happens every time.

## Installation

Add `replayx` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:replayx, "~> 0.1.0"}
  ]
end
```

## Quick start

1. **Use the instrumented GenServer** and put the recorder/replayer in state:

```elixir
defmodule MyServer do
  use Replayx.GenServer

  def init([recorder_pid]) when is_pid(recorder_pid) do
    {:ok, %{replayx_recorder: recorder_pid}}
  end

  def init([{:replayx_replayer, agent_pid}]) do
    {:ok, %{replayx_replayer: agent_pid}}
  end

  def handle_call_impl(msg, from, state), do: {:reply, :ok, state}
  def handle_cast_impl(msg, state), do: {:noreply, state}
  def handle_info_impl(msg, state), do: {:noreply, state}
end
```

2. **Use `Replayx.Clock` and `Replayx.Rand`** in callbacks instead of `System` and `:rand` so time and randomness are recorded/replayed:

```elixir
def handle_info_impl(:tick, state) do
  _t = Replayx.Clock.monotonic_time()
  {:noreply, state}
end
```

3. **Record** a session (e.g. until crash):

```elixir
Replayx.record("trace.json", fn recorder_pid ->
  {:ok, pid} = MyServer.start_link(recorder_pid)
  send(pid, :tick)
  send(pid, :crash)
end)
```

4. **Replay** from code or CLI:

```elixir
Replayx.replay("trace.json", MyServer)
```

```bash
mix replay trace.json MyServer
```

## MVP scope

- Single GenServer, local node only
- Record & replay crashes, CLI replay
- No distributed nodes, time-travel UI, Phoenix, or ETS replay

See [DESIGN.md](DESIGN.md) for architecture and prior art.

## License

Apache 2.0
