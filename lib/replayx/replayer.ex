defmodule Replayx.Replayer do
  @moduledoc """
  Replay engine: loads a trace file and runs the GenServer callbacks in order,
  feeding recorded messages and supplying recorded time/rand from the trace.
  """

  @doc """
  Runs replay for a trace file and module. The module must use Replayx.GenServer
  and its init must accept `[{:replayx_replayer, agent_pid}]` and put
  `replayx_replayer: agent_pid` in state.

  Options:
    * `:step_fun` – optional function `(seq, kind, payload, state_after) -> :continue | :stop`.
      When set, replay pauses after each message and calls this callback; return `:stop` to
      end replay early (time-travel / step-through mode).

  Returns `{:ok, final_state}` if replay completes, or raises on divergence/crash.
  """
  @spec run(String.t(), module(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(trace_path, module, opts \\ []) do
    _ = Application.ensure_all_started(:telemetry)
    :telemetry.execute([:replayx, :replayer, :start], %{}, %{path: trace_path, module: module})

    {_metadata, events} = Replayx.Trace.read(trace_path)
    {:ok, agent_pid} = Replayx.ReplayerState.start_link(events)
    Process.put(:replayx_replayer, agent_pid)
    Process.delete(:replayx_recorder)

    step_fun = Keyword.get(opts, :step_fun)

    result =
      try do
        case module.init([{:replayx_replayer, agent_pid}]) do
          {:ok, state} -> replay_loop(module, state, agent_pid, step_fun)
          other -> {:error, {:init_failed, other}}
        end
      rescue
        e ->
          {:error, {:crash, e, __STACKTRACE__}}
      after
        Process.delete(:replayx_replayer)
        Agent.stop(agent_pid)
      end

    :telemetry.execute(
      [:replayx, :replayer, :stop],
      %{},
      %{path: trace_path, module: module, result: result}
    )

    case result do
      {:error, {:crash, e, stack}} -> reraise e, stack
      other -> other
    end
  end

  defp replay_loop(module, state, agent_pid, step_fun) do
    Process.put(:replayx_replayer, agent_pid)
    Process.delete(:replayx_recorder)

    case Replayx.ReplayerState.pop_message(agent_pid) do
      :empty ->
        {:ok, state}

      {seq, :call, from, payload} ->
        apply_call_result(module, payload, from, state)
        |> maybe_step_loop(module, seq, :call, payload, agent_pid, step_fun)

      {seq, :cast, _from, payload} ->
        apply_cast_result(module, payload, state)
        |> maybe_step_loop(module, seq, :cast, payload, agent_pid, step_fun)

      {seq, :info, _from, payload} ->
        apply_info_result(module, payload, state)
        |> maybe_step_loop(module, seq, :info, payload, agent_pid, step_fun)
    end
  end

  defp maybe_step_loop({:halt, new_state}, _module, _seq, _kind, _payload, _agent_pid, _step_fun) do
    {:ok, new_state}
  end

  defp maybe_step_loop({:continue, new_state}, module, seq, kind, payload, agent_pid, step_fun) do
    if step_continue?(step_fun, seq, kind, payload, new_state) do
      replay_loop(module, new_state, agent_pid, step_fun)
    else
      {:ok, new_state}
    end
  end

  defp step_continue?(nil, _seq, _kind, _payload, _state), do: true

  defp step_continue?(fun, seq, kind, payload, state) do
    case fun.(seq, kind, payload, state) do
      :continue -> true
      :stop -> false
      _ -> true
    end
  end

  defp apply_call_result(module, payload, from, state) do
    case module.handle_call_impl(payload, from, state) do
      {:reply, _reply, new_state} -> {:continue, new_state}
      {:reply, _reply, new_state, _timeout} -> {:continue, new_state}
      {:stop, _reason, _reply, new_state} -> {:halt, new_state}
      {:stop, _reason, new_state} -> {:halt, new_state}
      other -> raise "Replay: handle_call_impl returned unexpected #{inspect(other)}"
    end
  end

  defp apply_cast_result(module, payload, state) do
    case module.handle_cast_impl(payload, state) do
      {:noreply, new_state} -> {:continue, new_state}
      {:noreply, new_state, _timeout} -> {:continue, new_state}
      {:stop, _reason, new_state} -> {:halt, new_state}
      other -> raise "Replay: handle_cast_impl returned unexpected #{inspect(other)}"
    end
  end

  defp apply_info_result(module, payload, state) do
    case module.handle_info_impl(payload, state) do
      {:noreply, new_state} -> {:continue, new_state}
      {:noreply, new_state, _timeout} -> {:continue, new_state}
      {:stop, _reason, new_state} -> {:halt, new_state}
      other -> raise "Replay: handle_info_impl returned unexpected #{inspect(other)}"
    end
  end
end
