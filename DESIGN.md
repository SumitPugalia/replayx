# Design: Deterministic Replay System for Elixir Processes

> Reproduce production crashes deterministically by recording and replaying BEAM process execution.

## 1. Problem Statement

### The core problem

Debugging concurrent Elixir systems is fundamentally hard because **failures are non-deterministic**.

When a GenServer crashes in production, the root cause often depends on:

- message ordering
- timing
- random values
- external inputs

By the time the crash happens:

- logs are incomplete
- state is gone
- re-running the code locally **does not reproduce the bug**

### Why existing tools are insufficient

| Tool             | Limitation                     |
| ---------------- | ------------------------------ |
| Logger           | Observational, not causal      |
| `:dbg`, `:trace` | Too verbose, not replayable    |
| Telemetry        | Metrics, not execution         |
| Tests            | Don't capture real concurrency |
| Crash dumps      | Static snapshot only           |

👉 **There is no way today to deterministically replay a BEAM process execution.**

## 2. What This Project Does

Replayx introduces **record-and-replay debugging** for Elixir processes.

### High-level idea

1. **Record** everything that makes a process nondeterministic
2. **Persist** it in a trace file
3. **Replay** the exact execution later, deterministically

> Same messages. Same order. Same timing. Same crash.

## 3. MVP Scope

- ✅ Single GenServer
- ✅ Local node only
- ✅ Record & replay crashes
- ✅ CLI-based replay

- ❌ Distributed nodes
- ❌ Time-travel UI
- ❌ Phoenix requests
- ❌ ETS/global state replay

## 4. Determinism Model

We control **all sources of nondeterminism**:

- **Message ordering**: every message delivered to the GenServer is recorded in order (seq, kind, from, payload).
- **Time**: `Replayx.Clock.monotonic_time/1`, `system_time/1`, and `send_after/3` are virtualized (recorded in replay, replayed from trace).
- **Randomness**: `Replayx.Rand.uniform/0`, `uniform/1`, `seed/1` are recorded and replayed.
- **External inputs (MVP)**: record return values of injected functions only.

## 5. Architecture

```
Record:
  GenServer (instrumented) → Recorder → Trace file (JSON)

Replay:
  Trace file → ReplayerState (Agent) → Replayer runs handle_* in order
                ↓
  Clock / Rand pop next event from Agent
```

- **Replayx.GenServer**: wraps `handle_call` / `handle_cast` / `handle_info` to record messages and set process dict for Clock/Rand.
- **Replayx.Recorder**: GenServer that buffers events and writes JSON trace on stop.
- **Replayx.Clock / Replayx.Rand**: in record mode call real impl and record; in replay mode pop next event from ReplayerState Agent.
- **Replayx.Replayer**: loads trace, starts Agent with events, runs init then a loop of pop_message → handle_*_impl; same process so Clock/Rand can pop from Agent.

## 6. Trace File Format (JSON)

- `metadata`: elixir version, node.
- `events`: array of `{ type, ... }`. Types: `message` (seq, kind, from, payload), `time_monotonic`, `time_system`, `rand`, `rand_seed`, `send_after`. Payloads and pids are Base64-encoded terms.

## 7. Prior Art

- **rr (Linux)**: OS-level record/replay; we do actor-level.
- **Erlang tracing**: no replay, no determinism.
- **Elm debugger**: single-threaded, pure; BEAM is concurrent and effectful.
- **Temporal**: workflow replay; we do raw process execution.

## 8. Why This Is Novel for Elixir

- First deterministic replay on BEAM at process level.
- Leverages OTP semantics.
- Enables time-travel debugging, chaos+replay, crash reproduction as a service.
