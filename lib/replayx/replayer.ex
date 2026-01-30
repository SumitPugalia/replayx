defmodule Replayx.Replayer do
  @moduledoc """
  Replay engine: loads a trace file and runs the GenServer callbacks in order,
  feeding recorded messages and supplying recorded time/rand from the trace.
  """

  @doc """
  Runs replay for a trace file and module. The module must use Replayx.GenServer
  and its init must accept `[{:replayx_replayer, agent_pid}]` and put
  `replayx_replayer: agent_pid` in state.

  Returns `{:ok, final_state}` if replay completes, or raises on divergence/crash.
  """
  @spec run(String.t(), module()) :: {:ok, term()} | {:error, term()}
  def run(trace_path, module) do
    {_metadata, events} = Replayx.Trace.read(trace_path)
    {:ok, agent_pid} = Replayx.ReplayerState.start_link(events)
    Process.put(:replayx_replayer, agent_pid)
    Process.delete(:replayx_recorder)

    try do
      case module.init([{:replayx_replayer, agent_pid}]) do
        {:ok, state} -> replay_loop(module, state, agent_pid)
        other -> {:error, {:init_failed, other}}
      end
    after
      Process.delete(:replayx_replayer)
      Agent.stop(agent_pid)
    end
  end

  defp replay_loop(module, state, agent_pid) do
    Process.put(:replayx_replayer, agent_pid)
    Process.delete(:replayx_recorder)

    case Replayx.ReplayerState.pop_message(agent_pid) do
      :empty -> {:ok, state}
      {_seq, :call, from, payload} ->
        case module.handle_call_impl(payload, from, state) do
          {:reply, _reply, new_state} -> replay_loop(module, new_state, agent_pid)
          {:reply, _reply, new_state, _timeout} -> replay_loop(module, new_state, agent_pid)
          {:stop, _reason, _reply, new_state} -> {:ok, new_state}
          {:stop, _reason, new_state} -> {:ok, new_state}
          other -> raise "Replay: handle_call_impl returned unexpected #{inspect(other)}"
        end
      {_seq, :cast, _from, payload} ->
        case module.handle_cast_impl(payload, state) do
          {:noreply, new_state} -> replay_loop(module, new_state, agent_pid)
          {:noreply, new_state, _timeout} -> replay_loop(module, new_state, agent_pid)
          {:stop, _reason, new_state} -> {:ok, new_state}
          other -> raise "Replay: handle_cast_impl returned unexpected #{inspect(other)}"
        end
      {_seq, :info, _from, payload} ->
        case module.handle_info_impl(payload, state) do
          {:noreply, new_state} -> replay_loop(module, new_state, agent_pid)
          {:noreply, new_state, _timeout} -> replay_loop(module, new_state, agent_pid)
          {:stop, _reason, new_state} -> {:ok, new_state}
          other -> raise "Replay: handle_info_impl returned unexpected #{inspect(other)}"
        end
    end
  end
end
