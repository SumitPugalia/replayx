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

---

## 9. Production Considerations (MVP vs. Production)

**The current MVP is not designed for production “record everything.”**

### Why “50 GenServers all writing trace files” is a problem

- **I/O bottleneck**: Every message, time, and rand event is written. High-throughput processes would generate large volumes of writes.
- **Unbounded growth**: Trace files grow until recording stops. No built-in rotation, sampling, or retention.
- **Disk space**: Many processes × long sessions × large payloads can exhaust disk.
- **Overhead**: Recording adds work (serialization, Recorder casts) on every callback.

So: **do not run “record on” for all GenServers in production** with the current design.

### How production use would differ (future work)

| Concern | MVP (today) | Production-oriented approach |
|--------|------------|------------------------------|
| **What to record** | You start a recorder and one GenServer; everything is recorded until you stop. | **Selective**: record only specific processes (e.g. by name, by feature flag) or only when an error is likely (e.g. after a failure signal). |
| **When to capture** | Manual: you call `Replayx.record(...)` and drive the scenario. | **On-error or on-demand**: start recording when a process is about to do something risky, or **dump trace on crash** (ring buffer in memory, flush to storage only when the process crashes). |
| **Where it goes** | Single JSON file on disk, written when the recorder stops. | **Streaming / remote**: send events to a service (e.g. over the network), or write to a bounded buffer (e.g. ring buffer in memory) and persist only on crash or on demand. |
| **Retention** | One file per recording; you manage deletion. | **Bounded**: max size or max events per trace, rotation, TTL, or “keep last N traces per process.” |
| **Scale** | One process per recorder, local node. | **Sampling**: record 1% of processes or 1% of sessions; or record only processes that have crashed before (sticky sampling). |

### Feasible production patterns (without changing the library today)

1. **Reproduce in staging, not in prod**  
   Use Replayx in dev/staging: reproduce a bug from logs or a crash report, then record a trace there and replay locally. No recording in production.

2. **Capture on crash only (future)**  
   Keep a small in-memory ring buffer of the last N events per process. When the process crashes, flush that buffer to a trace file (or send it to a service). Then replay later. This limits I/O and storage to “only when something went wrong.”

3. **Explicit recording for a few processes**  
   In production, enable recording only for a small set of critical or previously failing processes (e.g. via config or feature flag), with short sessions and strict retention (e.g. overwrite one file per process, or upload then delete).

4. **Replay as a service**  
   Production sends trace data (or a trace file) to a separate “replay” environment that runs Replayx to reproduce the crash. Recording in prod can stay minimal (e.g. on-crash dump); heavy replay runs offline.

### Summary

- **Today**: Replayx is aimed at **local debugging and reproduction** (single process, local file, manual record/replay). Using it as “every GenServer writes a trace file in prod” would be a bottleneck and is not supported by design.
- **Production-ready use** would require selective recording, bounded buffers, on-crash or on-demand capture, and possibly streaming/remote storage—all of which are **out of scope for the current MVP** and left as future work.
