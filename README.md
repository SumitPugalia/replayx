# Replayx

> **Deterministic replay debugging for Elixir processes. Reproduce crashes. Kill Heisenbugs. Sleep better.**

Replayx records everything that makes a GenServer nondeterministic (messages, time, randomness) and lets you **replay** the same execution later. When a crash happens in production or in tests, you get a trace file; run replay and the crash happens again, deterministically, so you can add logging, breakpoints, or inspect state without guessing.

---

## What it does

- **Record** — While your instrumented GenServer runs, Replayx records each message (call/cast/info), virtualized time (`Replayx.Clock`), and virtualized randomness (`Replayx.Rand`), plus state snapshots after each callback.
- **Ring buffer** — Only the last N events (and states) are kept in memory (default 10; configurable). No unbounded growth.
- **Flush on crash** — The recorder monitors your GenServer. When it crashes, the buffer is written to a trace file (with optional crash reason in metadata). On normal stop, the buffer is flushed when you stop the recorder.
- **Replay** — Load the trace and run the same messages in order, with the same time and randomness. The crash reproduces; you see the same state and can debug with full context.
- **Production-friendly** — Timestamped trace files (no overwrite on restart), configurable directory and rotation (e.g. keep last 20 files or delete older than 7 days).

---

## Installation

Add `replayx` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:replayx, "~> 0.1.0"}
  ]
end
```

---

## Quick start

### 1. Use the instrumented GenServer

Replace `use GenServer` with `use Replayx.GenServer`. Implement `handle_*_impl` instead of `handle_*`, and accept both recorder (for record) and replayer (for replay) in `init`:

```elixir
defmodule MyServer do
  use Replayx.GenServer

  def start_link(recorder_pid) when is_pid(recorder_pid) do
    GenServer.start_link(__MODULE__, [recorder_pid], [])
  end

  def init(args) do
    state = %{}

    state =
      case args do
        [recorder_pid] when is_pid(recorder_pid) ->
          Replayx.Recorder.monitor(recorder_pid, self())  # flush on crash
          Map.put(state, :replayx_recorder, recorder_pid)

        [{:replayx_replayer, agent_pid}] ->
          Map.put(state, :replayx_replayer, agent_pid)

        _ ->
          state
      end

    {:ok, state}
  end

  def handle_call_impl(msg, _from, state), do: {:reply, :ok, state}
  def handle_cast_impl(_msg, state), do: {:noreply, state}
  def handle_info_impl(_msg, state), do: {:noreply, state}
end
```

- **`Replayx.Recorder.monitor(recorder_pid, self())`** — So when your process crashes, the recorder flushes the ring buffer to the trace file and stops.

### 2. Use virtualized time and randomness

In callbacks, use **`Replayx.Clock`** and **`Replayx.Rand`** instead of `System` and `:rand` so they are recorded and replayed:

```elixir
def handle_info_impl(:tick, state) do
  _t = Replayx.Clock.monotonic_time()
  {:noreply, state}
end
```

### 3. Record a session

Start a recorder, run your scenario, then stop (or let the process crash so the buffer is flushed automatically):

```elixir
Replayx.record(MyServer, fn recorder_pid ->
  {:ok, pid} = MyServer.start_link(recorder_pid)
  send(pid, :tick)
  send(pid, :crash)
  # Wait for crash (recorder flushes and stops) or call Replayx.Recorder.stop(recorder_pid)
  ref = Process.monitor(pid)
  receive do
    {:DOWN, ^ref, :process, ^pid, _} -> :ok
  end
end)
```

You can also pass an explicit path: `Replayx.record("path/to/trace.json", fn ... end)`.

### 4. Replay

From the CLI (replays **latest** trace for the module by default):

```bash
mix replay MyServer
mix replay path/to/trace.json MyServer
```

From code:

```elixir
Replayx.replay(MyServer)                    # latest trace in module's trace_dir
Replayx.replay("path/to/trace.json", MyServer)
```

Replay prints a **trace summary** (last N messages and state after each), then runs the same execution; if it crashes, you get the same crash with full context.

---

## Configuration (`use Replayx.GenServer`)

| Option | Default | Description |
|--------|---------|-------------|
| `trace_file` | module name → `"module_name.json"` | Base filename for traces. |
| `trace_dir` | `"traces"` | Directory for timestamped trace files (production). |
| `trace_buffer_size` | `10` | Number of events (and state snapshots) to keep in the ring buffer. |
| `trace_rotation` | `[]` | After each write: `[max_files: 20]` and/or `[max_days: 7]` to limit files. |

Example:

```elixir
use Replayx.GenServer,
  trace_file: "my_server.json",
  trace_dir: "traces",
  trace_buffer_size: 20,
  trace_rotation: [max_files: 20, max_days: 7]
```

- **Timestamped files** — When using a module with `trace_dir`, each flush writes to `trace_dir/<base>_<timestamp>.json` (e.g. `traces/my_server_20250131T123456Z.json`). Restarts do not overwrite previous traces.
- **Rotation** — Optional: keep only the last `max_files` and/or delete files older than `max_days`.

---

## Recording in detail

- **Ring buffer** — Only the last `trace_buffer_size` events (messages, time, rand, state snapshots) are kept. When the buffer is full, the oldest event is dropped.
- **When the trace is written**  
  - **On crash** — If you called `Replayx.Recorder.monitor(recorder_pid, self())` in `init`, the recorder monitors your process. When it exits (e.g. crash), the recorder flushes the buffer to the trace file (with optional `crash_reason` in metadata) and stops.  
  - **On normal stop** — When your `record` callback returns, `Replayx.Recorder.stop(recorder_pid)` is called if the recorder is still alive, which flushes the buffer and writes the trace.
- **Do not return from `record`** until the GenServer has finished handling the messages you sent (e.g. use `Process.monitor` and `receive {:DOWN, ...}` after sending a message that causes a crash).
- **Trace write failure** — `Replayx.Trace.write/3` returns `{:ok, :ok}` or `{:error, reason}` (e.g. disk full, permission). On failure the Recorder emits `[:replayx, :recorder, :trace_write_failed]` so you can attach to log or alert; the Recorder still stops.

---

## Replaying in detail

- **Trace summary** — Before replay runs, the CLI prints the last N messages and the state after each (from the ring buffer). Use this to see exactly what led to the crash.
- **Latest trace** — `mix replay MyServer` and `Replayx.replay(MyServer)` use the **newest** file in `trace_dir` matching `<base>_*.json`. To replay a specific file, pass the path.
- **Determinism** — Replay feeds the same messages in the same order and supplies the same time/randomness from the trace. If your callbacks use only `Replayx.Clock` and `Replayx.Rand` for time/randomness, the crash reproduces.

---

## CLI

| Command | Description |
|---------|-------------|
| `mix replay <Module>` | Replay the **latest** trace for that module (from `trace_dir`). |
| `mix replay <path.json> <Module>` | Replay the given trace file. |
| `mix replay.record <Module>` | Record the example CrashingGenServer (or instructions for other modules). |
| `mix replay.record <path.json> <Module>` | Record to the given path. |
| `mix git.install_hooks` | Install git pre-push hook (format, credo, dialyzer, test). |

---

## Example

The project includes a full example in `examples/record_and_replay.exs`:

```bash
mix run examples/record_and_replay.exs
```

It defines `Replayx.Examples.CrashingGenServer`, records a scenario (tick, tick, state, crash), writes a timestamped trace under `traces/`, then replays it so the crash reproduces with the same state.

---

## Scope and limitations (MVP)

- **Supported:** Single GenServer, local node, record & replay crashes, CLI replay, ring buffer, timestamped traces, rotation.
- **Not supported:** Distributed nodes, time-travel UI, Phoenix request replay, ETS/global state replay.

For production, use **capture-on-crash** (ring buffer + flush on DOWN) with timestamped files and rotation so you get a bounded number of trace files per server. See [DESIGN.md](DESIGN.md) for architecture and prior art.

---

## Telemetry

Replayx emits [Telemetry](https://hexdocs.pm/telemetry) events so you can hook metrics or logging:

| Event | When | Measurements | Metadata |
|-------|------|--------------|----------|
| `[:replayx, :recorder, :trace_written]` | After a trace is written (flush on stop or crash) | `event_count` | `path`, `crash_reason` (nil if normal stop) |
| `[:replayx, :recorder, :trace_write_failed]` | When trace write fails (e.g. disk full, permission) | `event_count` | `path`, `crash_reason`, `reason` |
| `[:replayx, :replayer, :start]` | When replay starts | — | `path`, `module` |
| `[:replayx, :replayer, :stop]` | When replay finishes (success or crash) | — | `path`, `module`, `result` (`{:ok, state}` or `{:error, reason}`) |

Example: attach to log or metrics:

```elixir
:telemetry.attach(
  "replayx-trace-written",
  [:replayx, :recorder, :trace_written],
  fn _name, measurements, metadata, _config ->
    Logger.info("Trace written", path: metadata.path, event_count: measurements.event_count, crash: metadata.crash_reason)
  end,
  nil
)
```

---

## Development

- `mix test` — run tests  
- `mix credo` — static analysis  
- `mix dialyzer` — type checking (builds PLT on first run)

### Pre-push checks (git hook)

Install the git pre-push hook so format, credo, dialyzer, and tests run before every `git push`:

```bash
mix git.install_hooks
```

If any check fails, the push is aborted. To run the same checks manually: `./script/pre-push` or `mix prepush`.

---

## License

Apache 2.0
