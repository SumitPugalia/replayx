# Replayx

[![Hex.pm](https://img.shields.io/hexpm/v/replayx.svg)](https://hex.pm/packages/replayx)
[![Hexdocs](https://img.shields.io/badge/docs-hexdocs.pm-purple)](https://hexdocs.pm/replayx)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

> **Deterministic replay debugging for Elixir GenServers.** Record what led to a crash, then replay it exactly—every time.

---

## Table of contents

- [What is Replayx?](#what-is-replayx)
- [Who is it for?](#who-is-it-for)
- [How it works (in 30 seconds)](#how-it-works-in-30-seconds)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Core concepts](#core-concepts)
- [Configuration](#configuration)
- [Recording and replaying in detail](#recording-and-replaying-in-detail)
- [CLI reference](#cli-reference)
- [Production readiness](#production-readiness)
- [DynamicSupervisor helper (production)](#dynamicsupervisor-helper-production)
- [Distributed traces](#distributed-traces)
- [Improvements and roadmap](#improvements-and-roadmap)
- [Limitations and scope](#limitations-and-scope)
- [Telemetry](#telemetry)
- [Development](#development)
- [License](#license)

---

## What is Replayx?

Replayx is a **record-and-replay** library for Elixir processes. It solves a painful problem:

**Your GenServer crashed in production (or in a flaky test). You have a crash report, but you can’t reproduce it locally.** Message order, timing, and randomness made the bug appear only once. Re-running the same code doesn’t crash.

Replayx lets you:

1. **Record** — While your GenServer runs, Replayx records every message, virtualized time, and virtualized randomness (and optional state snapshots) in a **ring buffer**.
2. **Flush on crash** — When the process crashes, the last N events are written to a **trace file**. No unbounded growth; you only keep what you need for debugging.
3. **Replay** — Load the trace and run the same messages in the same order, with the same time and randomness. **The crash reproduces.** You can add logging, breakpoints, or inspect state with full context.

So: **same messages, same order, same time, same randomness → same crash.** That’s deterministic replay.

---

## Who is it for?

- **Developers** debugging hard-to-reproduce GenServer crashes (production or tests).
- **Teams** who want a trace file to attach to bug reports and replay later.
- **Anyone** who has said “it only crashed once” or “it works on my machine.”

You need basic familiarity with Elixir and GenServers. No prior record/replay experience required.

---

## How it works (in 30 seconds)

- You swap `use GenServer` for `use Replayx.GenServer` and implement `handle_*_impl` instead of `handle_*`.
- You use **`Replayx.Clock`** and **`Replayx.Rand`** instead of `System` and `:rand` in callbacks so time and randomness are recorded and replayed.
- For **recording**: you start a recorder, pass its PID to your GenServer’s `init`, and call `Replayx.Recorder.monitor(recorder_pid, self())` so the buffer is flushed to a file when the process crashes (or when you stop the recorder).
- For **replay**: you run `mix replay path/to/trace.json MyModule` or `Replayx.replay(path, MyModule)` from code. The same execution runs again; if it crashed before, it crashes again, deterministically.

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

Then run:

```bash
mix deps.get
```

**Requirements:** Elixir 1.17+.

---

## Quick start

### Step 1: Use the instrumented GenServer

Replace `use GenServer` with `use Replayx.GenServer`. Implement **`handle_*_impl`** (not `handle_*`). In `init`, support both **record** (recorder PID) and **replay** (replayer agent) and call `Replayx.Recorder.monitor/2` when recording.

```elixir
defmodule MyApp.MyServer do
  use Replayx.GenServer

  def start_link(recorder_pid) when is_pid(recorder_pid) do
    GenServer.start_link(__MODULE__, [recorder_pid], [])
  end

  def init(args) do
    state = %{}

    state =
      case args do
        [recorder_pid] when is_pid(recorder_pid) ->
          Replayx.Recorder.monitor(recorder_pid, self())  # flush trace on crash
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

- **`Replayx.Recorder.monitor(recorder_pid, self())`** — When your process crashes, the recorder writes the ring buffer to a trace file and stops.

### Step 2: Use virtualized time and randomness

In callbacks, use **`Replayx.Clock`** and **`Replayx.Rand`** instead of `System` and `:rand` so they are recorded and replayed:

```elixir
def handle_info_impl(:tick, state) do
  _t = Replayx.Clock.monotonic_time()
  {:noreply, state}
end

def handle_info_impl(:roll, state) do
  n = Replayx.Rand.uniform(10)
  {:noreply, %{state | last_roll: n}}
end
```

### Step 3: Record a session

Start a recorder, drive your scenario, then stop (or let the process crash so the buffer is flushed automatically):

```elixir
Replayx.record(MyApp.MyServer, fn recorder_pid ->
  {:ok, pid} = MyApp.MyServer.start_link(recorder_pid)
  send(pid, :tick)
  send(pid, :crash)

  # Important: wait for the process to finish (or crash) before returning
  ref = Process.monitor(pid)
  receive do
    {:DOWN, ^ref, :process, ^pid, _} -> :ok
  end
end)
```

You can also pass an explicit path: `Replayx.record("path/to/trace.json", fn recorder_pid -> ... end)`.

### Step 4: Replay

From the command line (replays the **latest** trace for the module by default):

```bash
mix replay MyApp.MyServer
mix replay path/to/trace.json MyApp.MyServer
```

From code:

```elixir
Replayx.replay(MyApp.MyServer)                      # latest trace in module's trace_dir
Replayx.replay("path/to/trace.json", MyApp.MyServer)
```

Replay prints a **trace summary** (last N messages and state after each), then runs the same execution. If it crashed before, you get the same crash with full context.

---

## Core concepts

| Concept | Description |
|--------|-------------|
| **Ring buffer** | Only the last N events (messages, time, rand, state snapshots) are kept. When full, the oldest is dropped. Configurable via `trace_buffer_size`. |
| **Flush on crash** | If you call `Replayx.Recorder.monitor(recorder_pid, self())` in `init`, the recorder monitors your process. On `DOWN`, it writes the buffer to a trace file (with optional `crash_reason` in metadata) and stops. |
| **Trace file** | JSON (or binary ETF) with metadata and events. Timestamped filenames (e.g. `traces/my_server_20250131T123456Z.json`) avoid overwriting on restart. |
| **Determinism** | Replay feeds the same messages in the same order and supplies the same time/randomness from the trace. Use only `Replayx.Clock` and `Replayx.Rand` in callbacks for reproducible replay. |

---

## Configuration

Options for `use Replayx.GenServer`:

| Option | Default | Description |
|--------|---------|-------------|
| `trace_file` | module name → `"module_name.json"` | Base filename for traces. |
| `trace_dir` | `"traces"` | Directory for timestamped trace files. |
| `trace_buffer_size` | `10` | Number of events (and state snapshots) in the ring buffer. |
| `trace_rotation` | `[]` | After each write: `[max_files: 20]` and/or `[max_days: 7]` to limit files. |

Example:

```elixir
use Replayx.GenServer,
  trace_file: "my_server.json",
  trace_dir: "traces",
  trace_buffer_size: 20,
  trace_rotation: [max_files: 20, max_days: 7]
```

- **Timestamped files** — Each flush writes to `trace_dir/<base>_<timestamp>.json`. If the recorder is monitoring a process, the filename can include the monitored PID so multiple instances get distinct files.
- **Rotation** — Optional: keep only the last `max_files` and/or delete files older than `max_days`.

---

## Recording and replaying in detail

### Recording

- **Do not return from `record`** until the GenServer has finished handling the messages you sent (e.g. use `Process.monitor` and `receive {:DOWN, ...}` after sending a message that causes a crash).
- **Trace write failure** — `Replayx.Trace.write/3` returns `{:ok, :ok}` or `{:error, reason}`. On failure the Recorder emits `[:replayx, :recorder, :trace_write_failed]`; you can attach to log or alert. The Recorder still stops.

### Replaying

- **Trace summary** — Before replay runs, the CLI prints the last N messages and the state after each. Use this to see what led to the crash.
- **Latest trace** — `mix replay MyModule` and `Replayx.replay(MyModule)` use the **newest** file in `trace_dir` matching `<base>_*.json`. Pass a path to replay a specific file.
- **Step-through (time-travel)** — Use `mix replay --step path Module` or `mix replay --step Module` to pause after each message, print payload and state, then continue (Enter) or stop (`q`+Enter). From code, pass `step_fun: fn seq, kind, payload, state -> :continue | :stop end` to `Replayx.replay/3`.

### Trace format and validation

- **Formats** — Default is JSON. For smaller/faster I/O: `Replayx.Trace.write(..., format: :binary)` and `Replayx.Trace.read(..., format: :auto)`. Optional **gzip**: pass `gzip: true` when writing; when reading, gzip is auto-detected by magic bytes.
- **Structured state** — Message payloads and state snapshots are serialized with `term_to_binary` (and Base64 in JSON). Structs (e.g. Ecto schemas) roundtrip if the struct module is loaded when replaying.
- **Validation** — `Replayx.Trace.valid?(path)` returns `{:ok, :valid}` or `{:error, reason}`. CLI: `mix replay --validate path.json Module` or `mix replay --validate Module`.

---

## CLI reference

| Command | Description |
|--------|-------------|
| `mix replay <Module>` | Replay the **latest** trace for that module (from `trace_dir`). |
| `mix replay <path.json> <Module>` | Replay the given trace file. |
| `mix replay --step <path> <Module>` or `mix replay --step <Module>` | Step-through replay: pause after each message; Enter to continue, `q`+Enter to stop. |
| `mix replay --validate <path> <Module>` or `mix replay --validate <Module>` | Validate trace file (no replay). |
| `mix replay.record <Module>` | Record the example (or instructions for other modules). |
| `mix replay.record <path.json> <Module>` | Record to the given path. |
| `mix git.install_hooks` | Install git pre-push hook (format, credo, dialyzer, test). |

---

## Production readiness

Use this checklist when preparing for production use (e.g. capture-on-crash with bounded disk).

### Checklist

- [ ] **`trace_buffer_size`** — Set large enough for the last N messages you care about before a crash (e.g. 20–50).
- [ ] **`trace_dir`** — Use a dedicated directory (e.g. `"traces"`); timestamped files go there so restarts don’t overwrite.
- [ ] **`trace_rotation`** — Set `[max_files: n]` and/or `[max_days: n]` to cap disk usage.
- [ ] **`Replayx.Recorder.monitor(recorder_pid, self())`** — Call in `init` when recording so the buffer flushes on crash.
- [ ] **Wait before returning from `record`** — Don’t return from `Replayx.record(module, fn ... end)` until the GenServer has finished handling the messages you sent (e.g. `Process.monitor` + `receive {:DOWN, ...}` after a message that causes a crash).
- [ ] **Time and randomness** — Use `Replayx.Clock` (e.g. `monotonic_time/0`, `send_after/3`) and `Replayx.Rand` (e.g. `uniform/1`) in callbacks so they are recorded and replayed.
- [ ] **Telemetry** — Attach to `[:replayx, :recorder, :trace_written]` and `[:replayx, :recorder, :trace_write_failed]` for logging/alerting.
- [ ] **Supervision** — For capture-on-crash in production, start the Recorder under your supervision tree (e.g. one Recorder per GenServer or per trace channel). When the GenServer crashes, the Recorder flushes and exits normally; use a DynamicSupervisor or one-for-one restart if you need a new Recorder for the restarted process.

### Supervision and the Recorder

- **Ad hoc recording (scripts, tests)** — Call `Replayx.record(module, fn recorder_pid -> ... end)`. Replayx starts the Recorder, runs your function, then stops the Recorder (or the Recorder stops itself when the monitored process crashes). The Recorder is short-lived and not a child of your app.
- **Production capture-on-crash** — Start the Recorder under your supervision tree and pass its PID to your GenServers’ `start_link`. In `init`, call `Replayx.Recorder.monitor(recorder_pid, self())` and store it in state. When the GenServer crashes, the Recorder flushes and exits with `:normal`; your supervisor can restart the child (and a new Recorder) if desired.
- **Multiple instances (DynamicSupervisor)** — Use one Recorder per GenServer child. With `dir` + `base_prefix` and `monitor`, each instance gets a distinct timestamped file that includes the monitored PID (e.g. `traces/my_server_0_123_0_20250131T123456Z.json`).

### DynamicSupervisor helper (production)

Use **`Replayx.TracedServerStarter`** to start a Recorder + GenServer pair under a DynamicSupervisor. When the GenServer crashes, the Recorder flushes the trace and exits; the Starter exits so the DynamicSupervisor can restart a new pair.

1. Add a DynamicSupervisor to your supervision tree:

```elixir
children = [
  {DynamicSupervisor, strategy: :one_for_one, name: MyApp.TracedWorkers},
  # ...
]
```

2. Start a traced GenServer under it:

```elixir
# Start with default options (trace_dir from module)
Replayx.TracedServerStarter.start_child(MyApp.TracedWorkers, MyApp.MyServer)

# With name and custom trace_dir (e.g. for tests or config)
Replayx.TracedServerStarter.start_child(MyApp.TracedWorkers, MyApp.MyServer, [], [
  name: MyApp.MyServer,
  trace_dir: Application.get_env(:my_app, :trace_dir, "traces")
])
```

Your GenServer must `use Replayx.GenServer` and in `init` handle `[recorder_pid | rest]` when `recorder_pid` is a pid: call `Replayx.Recorder.monitor(recorder_pid, self())` and put `replayx_recorder: recorder_pid` in state. Use `Replayx.Clock` and `Replayx.Rand` in callbacks for determinism.

Options passed to `start_child/4` can include `:name`, `:trace_buffer_size`, `:trace_dir`, `:trace_rotation`, and any [GenServer.start_link/3](https://hexdocs.pm/elixir/GenServer.html#start_link/3) option (e.g. `:timeout`).

---

## Distributed traces

Traces recorded when messages come from **other nodes** (e.g. `GenServer.call(server, msg)` from a remote node) include:

- **Metadata** — `"node"` and `"receiver_node"` (where the GenServer ran).
- **Message events** — `"from_node"` (sender node) when `from` is a PID; decoded back as a 6-tuple `{:message, seq, kind, from, payload, [from_node: node_string]}`.

**Ordering** — The trace order is the **processing order** on the GenServer. Replay feeds messages in that order on a single node, so the same crash reproduces. No cross-node ordering is required for single-process replay.

**Helpers** — Use `Replayx.Trace.distributed?(events)` to detect distributed traces, and `Replayx.Trace.message_nodes(events)` to get `[{seq, from_node}]` for debugging or future multi-node replay tooling.

**CLI** — When you run `mix replay path Module`, if the trace has messages from other nodes, the CLI prints: `Distributed trace: N message(s) from other nodes (order preserved in replay)`.

Full **multi-node replay** (re-sending messages from the recorded nodes via RPC) is not implemented; the trace format and helpers support it as future work.

---

## Improvements and roadmap

### Current state (MVP)

- Single GenServer, local node.
- Record & replay crashes, CLI replay, ring buffer, timestamped traces, rotation.
- **DynamicSupervisor helper** — `Replayx.TracedServerStarter` for production (Recorder + GenServer pair under DynamicSupervisor).
- **Distributed traces** — Node identity in metadata and message events (`from_node`); ordering preserved; `Trace.distributed?/1`, `Trace.message_nodes/1`; CLI shows distributed info.
- Step-through replay (`mix replay --step`).
- Phoenix/request replay via record-in-controller pattern (see [DESIGN.md](DESIGN.md) and README “Phoenix / request replay” below).

### Planned improvements

| Area | Description |
|------|-------------|
| **Documentation** | Hex docs, more examples (Phoenix, Ecto), troubleshooting guide. |
| **Testing** | More property tests, CI (GitHub Actions), compatibility matrix (Elixir/OTP). |
| **Observability** | Additional telemetry spans, optional OpenTelemetry. |
| **Trace format** | Versioned trace schema for forward compatibility. |
| **Performance** | Lower overhead when recording (e.g. batching, sampling). |

### Roadmap (future scope)

- **Multi-node replay** — Re-send messages from recorded `from_node` (e.g. via RPC); trace format and helpers are in place.
- **Time-travel UI** — Browser or IDE UI to step through traces (CLI `--step` is implemented).
- **Phoenix / request replay** — Plug helper and request metadata in trace (pattern and replay from CLI are documented).
- **More virtualization** — Optional layers for file I/O, network, or other side effects (time and randomness are already virtualized via `Replayx.Clock` and `Replayx.Rand`).

---

## Limitations and scope

- **Supported:** Single GenServer, local node, record & replay crashes, CLI replay, ring buffer, timestamped traces, rotation, step-through replay, **TracedServerStarter** (DynamicSupervisor), **distributed trace metadata and ordering**, Phoenix/request replay via record-in-controller pattern.
- **Not supported:** Capture or replay of shared state outside the process (e.g. ETS, `:global`); use process-local state and `Replayx.Clock` / `Replayx.Rand` for determinism.

For production, use **capture-on-crash** (ring buffer + flush on DOWN) with timestamped files and rotation so you get a bounded number of trace files per server. See [DESIGN.md](DESIGN.md) for architecture and prior art.

### Phoenix / request replay

You can record a trace when a Phoenix (or Plug) request triggers GenServer behaviour, then replay from the CLI.

**Pattern:** In your controller or Plug, wrap the interaction in `Replayx.record/2` with a path that identifies the request (e.g. request id). The callback receives the recorder PID; start or look up your GenServer, pass the recorder to it if it uses `Replayx.GenServer`, then send the same messages you would for this request. Wait for the response (or crash) before returning so the trace is flushed.

```elixir
path = Path.join("traces", "my_server_#{request_id()}.json")
Replayx.record(path, fn recorder_pid ->
  {:ok, pid} = MyApp.MyServer.start_link(recorder_pid)  # or Registry.lookup(...)
  GenServer.call(pid, {:handle_request, conn.params})
end)
```

Replay: `mix replay path/to/trace.json MyApp.MyServer`. Your GenServer must `use Replayx.GenServer` and use `Replayx.Clock` / `Replayx.Rand` for determinism.

---

## Telemetry

Replayx emits [Telemetry](https://hexdocs.pm/telemetry) events:

| Event | When | Measurements | Metadata |
|-------|------|---------------|----------|
| `[:replayx, :recorder, :trace_written]` | After a trace is written (flush on stop or crash) | `event_count` | `path`, `crash_reason` (nil if normal stop) |
| `[:replayx, :recorder, :trace_write_failed]` | When trace write fails (e.g. disk full) | `event_count` | `path`, `crash_reason`, `reason` |
| `[:replayx, :replayer, :start]` | When replay starts | — | `path`, `module` |
| `[:replayx, :replayer, :stop]` | When replay finishes (success or crash) | — | `path`, `module`, `result` |

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

## Example

The project includes a full example in `examples/record_and_replay.exs`:

```bash
mix run examples/record_and_replay.exs
```

It defines `Replayx.Examples.CrashingGenServer`, records a scenario (tick, tick, state, crash), writes a timestamped trace under `traces/`, then replays it so the crash reproduces with the same state.

---

## Development

- **Tests:** `mix test` (includes property-based tests with [StreamData](https://hexdocs.pm/stream_data))
- **Format:** `mix format`
- **Static analysis:** `mix credo`
- **Types:** `mix dialyzer` (builds PLT on first run)

### Pre-push checks

Install the git pre-push hook so format, credo, dialyzer, and tests run before every `git push`:

```bash
mix git.install_hooks
```

To run the same checks manually: `./script/pre-push` or `mix prepush`.

### Contributing

Contributions are welcome. Please open an issue or PR on the project repository. Ensure tests pass and follow the project’s formatting and style (Credo, Dialyzer).

---

## License

Copyright 2025. Licensed under the [Apache License, Version 2.0](LICENSE).
