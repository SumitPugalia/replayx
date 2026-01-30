defmodule Replayx.Recorder do
  @moduledoc """
  Records trace events in a ring buffer and writes them to a JSON file on stop or on crash.
  Used only in record mode. Keeps the last N events (messages + state snapshots) for easy debugging.
  """

  use GenServer

  @type event :: Replayx.Trace.event()

  defstruct dir: nil,
            base_prefix: nil,
            path: nil,
            rotation: [],
            buffer: [],
            buffer_size: 10,
            seq: 0,
            monitored_ref: nil

  @doc """
  Starts a recorder that will write when stopped or when the monitored process crashes.
  Two modes:
    * Single path: `start_link("trace.json", buffer_size: 10)` – writes to that path (no timestamp, no rotation).
    * Timestamped (production): pass opts with `:dir`, `:base_prefix`, and optionally `:rotation`. Each flush writes to `dir/base_prefix_<timestamp>.json` and applies rotation.
  Options: `:buffer_size`, `:dir`, `:base_prefix`, `:rotation` (keyword list for `Replayx.Trace.rotate/3`).
  """
  @spec start_link(String.t(), keyword()) :: GenServer.on_start()
  def start_link(path, opts \\ []) when is_binary(path) do
    buffer_size = Keyword.get(opts, :buffer_size, 10)
    dir = Keyword.get(opts, :dir)
    base_prefix = Keyword.get(opts, :base_prefix)
    rotation = Keyword.get(opts, :rotation, [])
    GenServer.start_link(__MODULE__, {path, buffer_size, dir, base_prefix, rotation}, [])
  end

  @doc """
  Records an event. Events are kept in a ring buffer (last N). On stop or crash, the buffer is flushed to the trace file.
  """
  @spec record_event(pid() | atom(), event()) :: :ok
  def record_event(recorder_pid, event) do
    GenServer.cast(recorder_pid, {:record, event})
  end

  @doc """
  Monitors the given process. When it crashes (DOWN), the recorder flushes the buffer to the trace file and stops.
  Call this from your GenServer's init when you have the recorder pid (e.g. `Replayx.Recorder.monitor(recorder_pid, self())`).
  """
  @spec monitor(pid() | atom(), pid()) :: :ok
  def monitor(recorder_pid, pid) when is_pid(pid) do
    GenServer.cast(recorder_pid, {:monitor, pid})
  end

  @doc """
  Stops the recorder and flushes the current buffer to the trace file.
  """
  @spec stop(pid() | atom()) :: :ok
  def stop(recorder_pid) do
    GenServer.call(recorder_pid, :stop, :infinity)
  end

  @doc """
  Allocates the next message sequence number.
  """
  @spec next_seq(pid() | atom()) :: non_neg_integer()
  def next_seq(recorder_pid) do
    GenServer.call(recorder_pid, :next_seq, :infinity)
  end

  @impl GenServer
  def init({path, buffer_size, dir, base_prefix, rotation}) do
    state = %__MODULE__{
      path: path,
      dir: dir,
      base_prefix: base_prefix,
      rotation: rotation,
      buffer_size: buffer_size
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:record, event}, state) do
    buffer = [event | state.buffer] |> Enum.take(state.buffer_size)
    {:noreply, %{state | buffer: buffer}}
  end

  @impl GenServer
  def handle_cast({:monitor, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, %{state | monitored_ref: ref}}
  end

  @impl GenServer
  def handle_call(:next_seq, _from, state) do
    seq = state.seq
    {:reply, seq, %{state | seq: seq + 1}}
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    flush_to_file(state, nil)
    {:stop, :normal, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if ref == state.monitored_ref do
      flush_to_file(state, reason)
      {:stop, :normal, state}
    else
      {:noreply, state}
    end
  end

  defp flush_to_file(state, crash_reason) do
    events = Enum.reverse(state.buffer)
    metadata = if crash_reason, do: %{"crash_reason" => inspect(crash_reason)}, else: %{}
    path = resolve_path(state)
    Replayx.Trace.write(path, events, metadata)

    :telemetry.execute(
      [:replayx, :recorder, :trace_written],
      %{event_count: length(events)},
      %{path: path, crash_reason: crash_reason}
    )

    if state.dir && state.base_prefix && state.rotation != [] do
      Replayx.Trace.rotate(state.dir, state.base_prefix, state.rotation)
    end
  end

  defp resolve_path(%{dir: dir, base_prefix: base}) when is_binary(dir) and is_binary(base) do
    Replayx.Trace.path_with_timestamp(dir, base)
  end

  defp resolve_path(state), do: state.path
end
