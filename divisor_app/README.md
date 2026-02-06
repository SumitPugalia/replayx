# DivisorApp

A minimal Phoenix app that demonstrates **Replayx** in a real scenario: a divisor GenServer (10 / divisor) that crashes on division by zero, with traces written so you can replay the crash.

## Setup

From the **replayx** repo root:

```bash
cd divisor_app
mix setup
```

## Run

```bash
mix phx.server
```

Open http://localhost:4000. Enter a divisor (0–5) and click **Divide 10 by this**. Divisor 0 crashes the server; the trace is written to `divisor_app/traces/`.

## Replay after a crash

**Where to run:** Always run `mix replay` from **divisor_app** (the app that defines `DivisorApp.DivisorGenServer`). Running it from the replayx repo root will fail with “module not in the current project”.

1. **Record a trace first:** Start the app (`mix phx.server`), open http://localhost:4000, and trigger a crash (e.g. divide by 0). The trace is written to `traces/`.
2. **Replay** (from `divisor_app`):

```bash
cd divisor_app
mix replay DivisorApp.DivisorGenServer
```

This replays the latest trace and reproduces the crash deterministically.

## How it works

- **DivisorGenServer** uses `Replayx.GenServer`; all messages are recorded.
- It is started under a **DynamicSupervisor** via **Replayx.TracedServerStarter** (Recorder + GenServer pair).
- On crash, the Recorder flushes the ring buffer to a timestamped JSON file in `traces/`.
- The web UI can **Restart divisor server** to start a new pair after a crash.

## Replayx

Replayx is included as a path dependency (`path: ".."`). See the parent repo for full documentation.
