defmodule Replayx do
  @moduledoc """
  Deterministic replay debugging for Elixir processes.
  Reproduce crashes. Kill Heisenbugs. Sleep better.

  ## Record mode

      1. Start a recorder and your instrumented GenServer with the recorder pid in state.
      2. Interact with the GenServer (send messages, call, cast).
      3. Stop the recorder to flush the trace to a file.

  Example:

      Replayx.record("trace.json", fn recorder_pid ->
        {:ok, pid} = MyApp.MyServer.start_link([recorder_pid])
        GenServer.call(pid, :do_something)
        GenServer.call(pid, :crash)
      end)

  ## Replay mode

      mix replay trace.json MyApp.MyServer

  Or from code:

      Replayx.replay("trace.json", MyApp.MyServer)

  Your GenServer must `use Replayx.GenServer` and use `Replayx.Clock` / `Replayx.Rand`
  instead of `System` / `:rand` in callbacks so that time and randomness are deterministic.
  """

  @doc """
  Runs the given function with a recorder started; when the function returns,
  the recorder is stopped and the trace is written to `path`.
  The function receives the recorder pid — pass it to your GenServer's init.
  """
  @spec record(String.t(), (pid() -> term())) :: term()
  def record(path, fun) when is_binary(path) and is_function(fun, 1) do
    {:ok, recorder_pid} = Replayx.Recorder.start_link(path)
    try do
      fun.(recorder_pid)
    after
      Replayx.Recorder.stop(recorder_pid)
    end
  end

  @doc """
  Replays the trace file with the given module. The module must use Replayx.GenServer
  and its init must accept `[{:replayx_replayer, agent_pid}]` and put that in state.
  Returns `{:ok, final_state}` or `{:error, reason}`.
  """
  @spec replay(String.t(), module()) :: {:ok, term()} | {:error, term()}
  def replay(path, module) when is_binary(path) do
    Replayx.Replayer.run(path, module)
  end
end
