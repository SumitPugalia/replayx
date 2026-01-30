defmodule Replayx.Rand do
  @moduledoc """
  Virtualized randomness for record/replay.
  In record mode: calls real :rand and records the result.
  In replay mode: returns the next recorded value.
  """

  @doc """
  Uniform float in (0.0, 1.0]. Recorded and replayed.
  """
  @spec uniform() :: float()
  def uniform do
    case Process.get(:replayx_recorder) do
      nil ->
        case Process.get(:replayx_replayer) do
          nil -> :rand.uniform()
          agent_pid -> pop_rand_value(agent_pid)
        end

      recorder_pid ->
        value = :rand.uniform()
        Replayx.Recorder.record_event(recorder_pid, {:rand, value})
        value
    end
  end

  @doc """
  Uniform integer in 1..max. Recorded and replayed (via recording uniform and deriving).
  For simplicity we record the result of uniform() and the max; on replay we only have
  the value. So we record {:rand, value} for uniform() and for uniform(n) we could
  record {:rand_uniform_n, value}. Let's keep it simple: uniform(n) = floor(uniform() * n) + 1,
  but that's not deterministic with a single float. So we record each call: uniform() -> {:rand, float},
  uniform(n) -> we can record the float and n, or just the result. Recording the result is simpler.
  """
  @spec uniform(pos_integer()) :: pos_integer()
  def uniform(max) when is_integer(max) and max >= 1 do
    case Process.get(:replayx_recorder) do
      nil ->
        case Process.get(:replayx_replayer) do
          nil -> :rand.uniform(max)
          agent_pid -> pop_rand_value_int(agent_pid)
        end

      recorder_pid ->
        value = :rand.uniform(max)
        Replayx.Recorder.record_event(recorder_pid, {:rand, value + 0.0})
        value
    end
  end

  @doc """
  Seeds the random algorithm. Recorded and replayed.
  """
  @spec seed({integer(), integer(), integer()}) :: :ok
  def seed(seed) do
    case Process.get(:replayx_recorder) do
      nil ->
        case Process.get(:replayx_replayer) do
          nil -> :rand.seed(:exsss, seed)
          agent_pid -> pop_rand_seed(agent_pid)
        end

      recorder_pid ->
        :rand.seed(:exsss, seed)
        Replayx.Recorder.record_event(recorder_pid, {:rand_seed, seed})
        :ok
    end
  end

  defp pop_rand_value(agent_pid) do
    case Replayx.ReplayerState.pop(agent_pid) do
      {:rand, value} when is_float(value) -> value
      {other, _} -> raise "Replay divergence: expected rand float, got #{inspect(other)}"
      :empty -> :rand.uniform()
    end
  end

  defp pop_rand_value_int(agent_pid) do
    case Replayx.ReplayerState.pop(agent_pid) do
      {:rand, value} when is_float(value) -> trunc(value)
      {:rand, value} when is_integer(value) -> value
      {other, _} -> raise "Replay divergence: expected rand, got #{inspect(other)}"
      :empty -> :rand.uniform(1)
    end
  end

  defp pop_rand_seed(agent_pid) do
    case Replayx.ReplayerState.pop(agent_pid) do
      {:rand_seed, seed} ->
        :rand.seed(:exsss, seed)
        :ok

      {other, _} ->
        raise "Replay divergence: expected rand_seed, got #{inspect(other)}"

      :empty ->
        :ok
    end
  end
end
