# Replayx

[![Hex.pm](https://img.shields.io/hexpm/v/replayx.svg)](https://hex.pm/packages/replayx)
[![Hexdocs](https://img.shields.io/badge/docs-hexdocs.pm-purple)](https://hexdocs.pm/replayx)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

> **Deterministic replay debugging for Elixir GenServers.** Record what led to a crash, then replay it exactly—every time.

---

## Table of contents

- [What is Replayx?](#what-is-replayx)
- [Who is it for?](#who-is-it-for)
- [How it works](#how-it-works)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Core concepts](#core-concepts)
- [Keeping replay faithful](#keeping-replay-faithful)
- [Configuration](#configuration)
- [Recording and replaying](#recording-and-replaying)
- [CLI reference](#cli-reference)
- [Distributed traces](#distributed-traces)
- [Telemetry](#telemetry)
- [Example](#example)
- [Development](#development)
- [License](#license)

---

## What is Replayx?

Replayx is a **record-and-replay** library for Elixir processes. It solves a painful problem:

**Your GenServer crashed in production (or in a flaky test). You have a crash report, but you can't reproduce it locally.** Message order, timing, and randomness made the bug appear only once. Re-running the same code doesn't crash.

Replayx lets you:

1. **Record** — While your GenServer runs, Replayx records every message, virtualized time, and virtualized randomness (and state snapshots) in a **ring buffer**.
2. **Flush on crash** — When the process crashes, the last N events are written to a **trace file**. No unbounded growth.
3. **Replay** — Load the trace and run the same messages in the same order, with the same time and randomness. **The crash reproduces.**

**Same messages, same order, same time, same randomness → same crash.**

---

## Who is it for?

- **Developers** debugging hard-to-reproduce GenServer crashes (production or tests).
- **Teams** who want a trace file to attach to bug reports and replay later.
- **Anyone** who has said "it only crashed once" or "it works on my machine."

Basic familiarity with Elixir and GenServers is enough. No prior record/replay experience required.

---

## How it works

- Swap `use GenServer` for `use Replayx.GenServer` and implement `handle_*_impl` instead of `handle_*`.
- Use **`Replayx.Clock`** and **`Replayx.Rand`** instead of `System` and `:rand` in callbacks so time and randomness are recorded and replayed.
- **Recording:** Start a recorder, pass its PID to your GenServer's `init` (e.g. `[recorder_pid]`). The library monitors the process so the buffer flushes to a file when it crashes (or when you stop the recorder).
- **Replay:** Run `mix replay path/to/trace.json MyModule` or `Replayx.replay(path, MyModule)` from code. The same execution runs again; if it crashed before, it crashes again, deterministically.

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

Then run `mix deps.get`.

**Requirements:** Elixir 1.17+

---

## Quick start

### Step 1: Use the instrumented GenServer

Replace `use GenServer` with `use Replayx.GenServer`. Implement **`init_impl/1`** (return your initial state) and **`handle_*_impl`** (not `handle_*`). The library injects `replayx_recorder` or `replayx_replayer` and calls `Replayx.Recorder.monitor/2` when recording.

```elixir
defmodule MyApp.MyServer do
  use Replayx.GenServer

  def start_link(recorder_pid) when is_pid(recorder_pid) do
    GenServer.start_link(__MODULE__, [recorder_pid], [])
  end

  def init_impl(_args), do: {:ok, %{}}

  def handle_call_impl(msg, _from, state), do: {:reply, :ok, state}
  def handle_cast_impl(_msg, state), do: {:noreply, state}
  def handle_info_impl(_msg, state), do: {:noreply, state}
end
```

### Step 2: Use virtualized time and randomness

In callbacks, use **`Replayx.Clock`** and **`Replayx.Rand`** instead of `System` and `:rand`:

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

Start a recorder, drive your scenario, then stop (or let the process crash so the buffer flushes automatically):

```elixir
Replayx.record(MyApp.MyServer, fn recorder_pid ->
  {:ok, pid} = MyApp.MyServer.start_link(recorder_pid)
  send(pid, :tick)
  send(pid, :crash)

  ref = Process.monitor(pid)
  receive do
    {:DOWN, ^ref, :process, ^pid, _} -> :ok
  end
end)
```

You can also pass an explicit path: `Replayx.record("path/to/trace.json", fn recorder_pid -> ... end)`.

### Step 4: Replay

**CLI** (replays the latest trace for the module by default):

```bash
mix replay MyApp.MyServer
mix replay path/to/trace.json MyApp.MyServer
```

**From code:**

```elixir
Replayx.replay(MyApp.MyServer)
Replayx.replay("path/to/trace.json", MyApp.MyServer)
```

Replay prints a **trace summary** (last N messages and state after each), then runs the same execution. If it crashed before, you get the same crash with full context.

---

## Core concepts

| Concept | Description |
| :------ | :---------- |
| **Ring buffer** | Only the last N events (messages, time, rand, state snapshots) are kept. When full, the oldest is dropped. Configurable via `trace_buffer_size`. |
| **Flush on crash** | When you pass `[recorder_pid]` in init, the library calls `Replayx.Recorder.monitor/2` and injects `replayx_recorder`. On `DOWN`, the recorder writes the buffer to a trace file (with optional `crash_reason` in metadata) and stops. |
| **Trace file** | JSON (or binary ETF) with metadata and events. Timestamped filenames (e.g. `traces/my_server_20250131T123456Z.json`) avoid overwriting on restart. |
| **Determinism** | Replay feeds the same messages in the same order and supplies the same time/randomness from the trace. Use only `Replayx.Clock` and `Replayx.Rand` in callbacks for reproducible replay. |

---

## Keeping replay faithful

Replay stays deterministic only if **inside your GenServer callbacks** you use Replayx’s virtualized time, randomness, and timers. If you call `System`, `:rand`, or `Process.send_after` directly in a callback, those values are not recorded, so during replay you get different values and the run can **diverge** (different path, no crash, or misleading trace).

**Use the Replayx replacements in callbacks:**

| In callback, avoid | Use instead | Why |
| :----------------- | :---------- | :-- |
| `System.monotonic_time/1` | `Replayx.Clock.monotonic_time/1` | Same time value on replay. |
| `System.system_time/1` | `Replayx.Clock.system_time/1` | Same time value on replay. |
| `:rand.uniform()` / `:rand.uniform(n)` | `Replayx.Rand.uniform()` / `Replayx.Rand.uniform(n)` | Same random value on replay. |
| `Process.send_after(ms, pid, msg)` | `Replayx.Clock.send_after(ms, pid, msg)` | Same ref and logical “when” on replay. |

**Time — don’t use `System` in callbacks:**

```elixir
# Replay can diverge (avoid)
def handle_info_impl(:check, state) do
  now = System.monotonic_time(:millisecond)
  if now > state.deadline, do: do_timeout(), else: :ok
  {:noreply, state}
end

# Replay stays faithful (do)
def handle_info_impl(:check, state) do
  now = Replayx.Clock.monotonic_time(:millisecond)
  if now > state.deadline, do: do_timeout(), else: :ok
  {:noreply, state}
end
```

**Random — don’t use `:rand` in callbacks:**

```elixir
# Replay can diverge (avoid)
def handle_info_impl(:roll, state) do
  n = :rand.uniform(10)
  {:noreply, %{state | last_roll: n}}
end

# Replay stays faithful (do)
def handle_info_impl(:roll, state) do
  n = Replayx.Rand.uniform(10)
  {:noreply, %{state | last_roll: n}}
end
```

**Timers — don’t use `Process.send_after` in callbacks:**

```elixir
# Replay can diverge (avoid)
def handle_call_impl(:schedule_tick, _from, state) do
  ref = Process.send_after(self(), :tick, 1000)
  {:reply, :ok, %{state | tick_ref: ref}}
end

# Replay stays faithful (do)
def handle_call_impl(:schedule_tick, _from, state) do
  ref = Replayx.Clock.send_after(1000, self(), :tick)
  {:reply, :ok, %{state | tick_ref: ref}}
end
```

Messages sent **to** the GenServer (e.g. via `Process.send`, HTTP, or another process) are always recorded and replayed; the rule applies only to code **inside** the callbacks.

---

## Configuration

Options for `use Replayx.GenServer`:

| Option | Default | Description |
| :----- | :------ | :---------- |
| `trace_file` | module name → `"module_name.json"` | Base filename for traces. |
| `trace_dir` | `"traces"` | Directory for timestamped trace files. |
| `trace_buffer_size` | `10` | Number of events (and state snapshots) in the ring buffer. |
| `trace_rotation` | `[]` | After each write: `[max_files: 20]` and/or `[max_days: 7]` to limit files. |

**Example:**

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

## Recording and replaying

### Recording

- **Do not return from `record`** until the GenServer has finished handling the messages you sent (e.g. use `Process.monitor` and `receive {:DOWN, ...}` after sending a message that causes a crash).
- **Trace write failure** — On failure the Recorder emits `[:replayx, :recorder, :trace_write_failed]`; attach to log or alert. The Recorder still stops.
- **TracedServerStarter (production)** — When you start a Recorder + GenServer pair with `Replayx.TracedServerStarter`, the starter traps exits so that when the GenServer crashes, the Recorder can receive `DOWN`, flush the trace file, and exit before the starter exits. Use the **divisor_app** example as the reference.

### Replaying

- **Trace summary** — Before replay runs, the CLI prints the last N messages and the state after each.
- **Latest trace** — `mix replay MyModule` and `Replayx.replay(MyModule)` use the newest file in `trace_dir` matching `<base>_*.json`. Pass a path to replay a specific file.
- **Step-through** — Use `mix replay --step path Module` or `mix replay --step Module` to pause after each message; Enter to continue, `q`+Enter to stop. From code, pass `step_fun: fn seq, kind, payload, state -> :continue | :stop end` to `Replayx.replay/3`.

### Trace format and validation

- **Formats** — Default is JSON. For smaller/faster I/O: `Replayx.Trace.write(..., format: :binary)` and `Replayx.Trace.read(..., format: :auto)`. Optional **gzip**: pass `gzip: true` when writing; when reading, gzip is auto-detected.
- **Structured state** — Message payloads and state snapshots are serialized with `term_to_binary` (and Base64 in JSON). Structs (e.g. Ecto schemas) roundtrip if the struct module is loaded when replaying.
- **Validation** — `Replayx.Trace.valid?(path)` returns `{:ok, :valid}` or `{:error, reason}`. CLI: `mix replay --validate path.json Module` or `mix replay --validate Module`.

---

## CLI reference

| Command | Description |
| :------ | :---------- |
| `mix replay <Module>` | Replay the **latest** trace for that module (from `trace_dir`). |
| `mix replay <path.json> <Module>` | Replay the given trace file. |
| `mix replay --step <path> <Module>` or `mix replay --step <Module>` | Step-through replay. |
| `mix replay --validate <path> <Module>` or `mix replay --validate <Module>` | Validate trace file (no replay). |
| `mix replay.record <Module>` | Record the example (or instructions for other modules). |
| `mix replay.record <path.json> <Module>` | Record to the given path. |
| `mix git.install_hooks` | Install git pre-push hook (format, credo, dialyzer, test). |

---

## Distributed traces

When messages come from **other nodes**, traces include:

- **Metadata** — `"node"` and `"receiver_node"` (where the GenServer ran).
- **Message events** — `"from_node"` (sender node) when `from` is a PID; decoded as a 6-tuple `{:message, seq, kind, from, payload, [from_node: node_string]}`.

**Ordering** — The trace order is the processing order on the GenServer. Replay feeds messages in that order on a single node. No cross-node ordering is required for single-process replay.

**Helpers** — `Replayx.Trace.distributed?(events)` and `Replayx.Trace.message_nodes(events)` return `[{seq, from_node}]` for debugging.

**CLI** — When the trace has messages from other nodes, the CLI prints: `Distributed trace: N message(s) from other nodes (order preserved in replay)`.

---

## Telemetry

| Event | When | Measurements | Metadata |
| :---- | :--- | :------------ | :------- |
| `[:replayx, :recorder, :trace_written]` | After a trace is written (flush on stop or crash) | `event_count` | `path`, `crash_reason` (nil if normal stop) |
| `[:replayx, :recorder, :trace_write_failed]` | When trace write fails (e.g. disk full) | `event_count` | `path`, `crash_reason`, `reason` |
| `[:replayx, :replayer, :start]` | When replay starts | — | `path`, `module` |
| `[:replayx, :replayer, :stop]` | When replay finishes (success or crash) | — | `path`, `module`, `result` |

**Example:**

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

Run the full example:

```bash
mix run examples/record_and_replay.exs
```

It defines `Replayx.Examples.CrashingGenServer`, records a scenario (tick, tick, state, crash), writes a timestamped trace under `traces/`, then replays it so the crash reproduces.

---

## Development

- **Tests** — `mix test` (includes property-based tests with [StreamData](https://hexdocs.pm/stream_data))
- **Format** — `mix format`
- **Static analysis** — `mix credo`
- **Types** — `mix dialyzer` (builds PLT on first run)

### Pre-push checks

```bash
mix git.install_hooks
```

To run the same checks manually: `./script/pre-push` or `mix prepush`.

### Contributing

Contributions are welcome. Open an issue or PR. Ensure tests pass and follow the project's formatting and style (Credo, Dialyzer).

---

## License

Copyright 2025. Licensed under the [Apache License, Version 2.0](LICENSE).
