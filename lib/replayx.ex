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
  the recorder is stopped and the trace is written to the path.
  The function receives the recorder pid — pass it to your GenServer's init.

  You can pass either a path or a module that uses Replayx.GenServer with a `trace_file` option:
  - `record(path, fun)` – use `path` as the trace file (e.g. `"trace.json"`).
  - `record(module, fun)` – use the module's default trace file from `use Replayx.GenServer, trace_file: "..."`.

  **Important:** Do not return from the function until the GenServer has finished
  processing all messages you sent. Otherwise the recorder is stopped while the
  server still tries to record (e.g. `next_seq`) and you get an EXIT. Use sync
  calls or wait for the process to exit (e.g. `Process.monitor` + `assert_receive {:DOWN, ...}`)
  before returning.
  """
  @spec record(String.t() | module(), (pid() -> term())) :: term()
  def record(path_or_module, fun) when is_function(fun, 1) do
    path = trace_path(path_or_module)
    opts = record_opts(path_or_module)
    {:ok, recorder_pid} = Replayx.Recorder.start_link(path, opts)

    try do
      fun.(recorder_pid)
    after
      if Process.alive?(recorder_pid) do
        try do
          Replayx.Recorder.stop(recorder_pid)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  defp record_opts(path) when is_binary(path), do: []

  defp record_opts(module) when is_atom(module),
    do: [buffer_size: module.__replayx_trace_buffer_size__()]

  @doc """
  Replays the trace file with the given module. The module must use Replayx.GenServer
  and its init must accept `[{:replayx_replayer, agent_pid}]` and put that in state.
  Returns `{:ok, final_state}` or `{:error, reason}`.

  You can pass either a path and module, or just the module:
  - `replay(path, module)` – use `path` as the trace file.
  - `replay(module)` – use the module's default trace file from `use Replayx.GenServer, trace_file: "..."`.
  """
  @spec replay(String.t(), module()) :: {:ok, term()} | {:error, term()}
  def replay(path, module) when is_binary(path) do
    Replayx.Replayer.run(path, module)
  end

  def replay(module) when is_atom(module) do
    path = module.__replayx_trace_file__()
    Replayx.Replayer.run(path, module)
  end

  defp trace_path(path) when is_binary(path), do: path
  defp trace_path(module) when is_atom(module), do: module.__replayx_trace_file__()
end
