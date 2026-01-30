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

- **Timestamped files** — When using a module with `trace_dir`, each flush writes to `trace_dir/<base>_<timestamp>.json` (e.g. `traces/my_server_20250131T123456Z.json`). If the recorder is monitoring a process (you called `Replayx.Recorder.monitor(recorder_pid, self())`), the filename includes the **monitored PID** (e.g. `traces/my_server_0_123_0_20250131T123456Z.json`) so multiple instances of the same GenServer get distinct trace files when they fail.
- **Rotation** — Optional: keep only the last `max_files` and/or delete files older than `max_days`.

---

## Recording in detail

- **Ring buffer** — Only the last `trace_buffer_size` events (messages, time, rand, state snapshots) are kept. When the buffer is full, the oldest event is dropped.
- **Multiple instances** — When using timestamped mode (`dir` + `base_prefix`) and `Replayx.Recorder.monitor(recorder_pid, self())`, the trace filename includes the monitored process PID. Use one recorder per GenServer instance (e.g. one per supervisor child); each instance then gets a distinct file (e.g. `my_server_0_123_0_20250131T123456Z.json`) when it crashes or when you stop the recorder.
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
- **Step-through (time-travel)** — Use `mix replay --step path Module` or `mix replay --step Module` to pause after each message, print payload and state, then continue (Enter) or stop (`q`+Enter). From code, pass `step_fun: fn seq, kind, payload, state -> ... end` to `Replayx.Replayer.run/3`; return `:continue` or `:stop`.

**Trace format** — Default is JSON (human-readable). For smaller/faster I/O you can use binary (ETF): `Replayx.Trace.write(path, events, meta, format: :binary)` and `Replayx.Trace.read(path, format: :auto)` (auto-detects JSON vs binary by content). **Optional gzip**: pass `gzip: true` when writing; when reading, gzip is auto-detected by magic bytes, or pass `gzip: true` explicitly. Use `.json.gz` or `.etf.gz` extensions for gzipped traces.

**Structured state (Ecto, structs)** — Message payloads and state snapshots are serialized with `term_to_binary` (and Base64 in JSON). Any serializable term roundtrips, including structs (e.g. Ecto schemas): ensure the struct module is loaded when replaying so decoded terms keep their `__struct__` and behaviour.

**Trace validation** — Check a trace file without full replay: `Replayx.Trace.valid?(path)` returns `{:ok, :valid}` or `{:error, reason}`. CLI: `mix replay --validate path.json Module` or `mix replay --validate Module`.

**Distributed nodes** — Trace metadata includes the recording node (`metadata["node"]`). For message events, when the sender is a PID, the trace includes `from_node` (sender’s node name) so cross-node calls are visible. You can replay on any node with the same code; message order is preserved. Further work (e.g. multi-node ordering guarantees) is in the roadmap.

**Virtualization scope** — Replayx virtualizes **time** (`Replayx.Clock`: monotonic, system, `send_after`) and **randomness** (`Replayx.Rand`: uniform, seed). File I/O, network, and other side effects are **not** virtualized; if your callbacks depend on them, replay may diverge. A future release may add optional layers to record/replay file or network operations.

---

## CLI

| Command | Description |
|---------|-------------|
| `mix replay <Module>` | Replay the **latest** trace for that module (from `trace_dir`). |
| `mix replay <path.json> <Module>` | Replay the given trace file. |
| `mix replay --step <path> <Module>` or `mix replay --step <Module>` | Step-through replay (time-travel): pause after each message, show payload and state; Enter to continue, `q`+Enter to stop. |
| `mix replay --validate <path> <Module>` or `mix replay --validate <Module>` | Validate trace file (no replay). |
| `mix replay.record <Module>` | Record the example CrashingGenServer (or instructions for other modules). |
| `mix replay.record <path.json> <Module>` | Record to the given path. |
| `mix git.install_hooks` | Install git pre-push hook (format, credo, dialyzer, test). |

---

## ETS / global state

Replayx records only **process-local state**: message payloads and the GenServer state snapshots you capture. It does **not** record or restore ETS tables, `:global` registry, or other shared state. If your GenServer reads or writes ETS (or global state) in callbacks, replay may diverge because that state is not replayed.

**Workaround:** Keep determinism by using only `Replayx.Clock` and `Replayx.Rand` for time/randomness and by avoiding ETS/global in the code path you want to replay, or by ensuring ETS/global are in a known state before replay (e.g. reset in test setup). A future release may add optional ETS snapshot events (record table contents on flush, restore on replay).

---

## Phoenix / request replay

You can record a trace when a Phoenix (or Plug) request triggers GenServer behaviour, then replay the same execution from the CLI.

**Pattern:** In your controller or Plug, when handling a request that sends work to a GenServer, wrap the interaction in `Replayx.record/2` and use a path that identifies the request (e.g. timestamp or request id). The callback receives the recorder pid; start or look up your GenServer (e.g. via registry), pass the recorder to it if it uses `Replayx.GenServer`, then send the same messages you would send for this request (e.g. from `conn.params` or body). Wait for the response (or crash) before returning from the callback so the trace is flushed.

Example (conceptual):

```elixir
# In a controller or Plug
path = Path.join("traces", "my_server_#{request_id()}.json")
Replayx.record(path, fn recorder_pid ->
  {:ok, pid} = MyApp.MyServer.start_link(recorder_pid)  # or Registry.lookup(...)
  GenServer.call(pid, {:handle_request, conn.params})
end)
```

Replay from the CLI: `mix replay path/to/trace.json MyApp.MyServer`. Your GenServer must `use Replayx.GenServer` and use `Replayx.Clock` / `Replayx.Rand` for determinism. A future release may add a Plug helper that wraps this pattern and optionally stores request metadata in the trace.

---

## Example

The project includes a full example in `examples/record_and_replay.exs`:

```bash
mix run examples/record_and_replay.exs
```

It defines `Replayx.Examples.CrashingGenServer`, records a scenario (tick, tick, state, crash), writes a timestamped trace under `traces/`, then replays it so the crash reproduces with the same state.

---

## Scope and limitations (MVP)

- **Supported:** Single GenServer, local node, record & replay crashes, CLI replay, ring buffer, timestamped traces, rotation, node identity in traces (distributed-aware), step-through replay (time-travel) via `mix replay --step`, Phoenix/request replay via record-in-controller pattern (see [Phoenix / request replay](#phoenix--request-replay)).
- **Not supported:** ETS / global state capture or replay (see [ETS / global state](#ets--global-state)).

For production, use **capture-on-crash** (ring buffer + flush on DOWN) with timestamped files and rotation so you get a bounded number of trace files per server. See [DESIGN.md](DESIGN.md) for architecture and prior art.

### Future scope / Roadmap

- **Distributed nodes** — Further: message ordering across nodes, multi-node replay guarantees (basic node identity in trace is implemented).
- **Time-travel UI** — Full UI (e.g. browser) to step through traces; CLI step-through (`--step`) is implemented.
- **Phoenix / request replay** — Plug helper and request metadata in trace (pattern and replay from CLI are documented).
- **ETS / global state** — Optional ETS snapshot events (record/restore table contents); limitation and workarounds are documented.
- **More virtualization** — File I/O, network, or other side effects as optional recorded/replayed layers (time and randomness are already virtualized via `Replayx.Clock` and `Replayx.Rand`).

### Production checklist

- **`trace_buffer_size`** — Set large enough for the last N messages you care about before a crash (e.g. 20–50).
- **`trace_dir`** — Use a dedicated directory (e.g. `"traces"`); timestamped files go there so restarts don’t overwrite.
- **`trace_rotation`** — Set `[max_files: n]` and/or `[max_days: n]` to cap disk usage.
- **`Replayx.Recorder.monitor(recorder_pid, self())`** — Call in `init` when recording so the buffer flushes on crash.
- **Wait before returning from `record`** — Don’t return from `Replayx.record(module, fn ... end)` until the GenServer has finished handling the messages you sent (e.g. `Process.monitor` + `receive {:DOWN, ...}` after a message that causes a crash).
- **Time and randomness** — Use `Replayx.Clock` (e.g. `monotonic_time/0`, `send_after/3`) and `Replayx.Rand` (e.g. `uniform/1`) in callbacks so they are recorded and replayed.

### Supervision and the Recorder

The **Recorder** is not started under your application’s supervision tree by default. The usual flow is:

1. **Ad hoc recording (e.g. scripts, tests)** — You call `Replayx.record(module, fn recorder_pid -> ... end)`. Replayx starts the Recorder, runs your function, then stops the Recorder (or the Recorder stops itself when the monitored process crashes). The Recorder is short-lived and not a child of your app.

2. **Production capture-on-crash** — If you want the Recorder to run for the lifetime of your app and capture crashes of one or more GenServers, you can start the Recorder under your supervision tree and pass its pid to your GenServers’ `start_link`. For example:
   - Start one Recorder per trace “channel” (e.g. per module or per logical server type) under a supervisor.
   - Your GenServer’s `init` receives the recorder pid (e.g. from application env or from a registry), calls `Replayx.Recorder.monitor(recorder_pid, self())`, and stores it in state.
   - When the GenServer crashes, the Recorder (which is still alive under the supervisor) flushes the ring buffer to a timestamped file and then stops itself (so you may want to use a DynamicSupervisor or one-for-one restart if you need a new Recorder for the restarted GenServer).

If the Recorder is **not** under your supervision tree (e.g. you only use `Replayx.record/2`), you don’t need to add it to your app. If you **do** supervise it, keep in mind that the Recorder exits with `:normal` after flushing on crash or on `stop/1`, so your supervisor will see a normal termination.

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

- `mix test` — run tests (includes property-based tests with [StreamData](https://hexdocs.pm/stream_data))  
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
