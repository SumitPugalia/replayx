defmodule Replayx.Recorder do
  @moduledoc """
  Records trace events and writes them to a JSON file on stop.
  Used only in record mode.
  """

  use GenServer

  @type event :: Replayx.Trace.event()

  defstruct path: nil, events: [], seq: 0

  @doc """
  Starts a recorder that will write to the given path when stopped.
  Returns `{:ok, pid}`. Pass this pid to your GenServer init and to `record/2`.
  """
  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(path) when is_binary(path) do
    GenServer.start_link(__MODULE__, path, [])
  end

  @doc """
  Records an event. Events are buffered until the recorder is stopped.
  """
  @spec record_event(pid() | atom(), event()) :: :ok
  def record_event(recorder_pid, event) do
    GenServer.cast(recorder_pid, {:record, event})
  end

  @doc """
  Stops the recorder and flushes all events to the trace file.
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
  def init(path) do
    state = %__MODULE__{path: path, events: [], seq: 0}
    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:record, event}, state) do
    state = %{state | events: [event | state.events]}
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:next_seq, _from, state) do
    seq = state.seq
    {:reply, seq, %{state | seq: seq + 1}}
  end

  @impl GenServer
  def handle_call(:stop, _from, state) do
    events = Enum.reverse(state.events)
    Replayx.Trace.write(state.path, events)
    {:stop, :normal, :ok, state}
  end
end
