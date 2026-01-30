defmodule Replayx.GenServer do
  @moduledoc """
  Instrumented GenServer that records or replays messages, time, and randomness.
  Use this instead of `use GenServer` when you want record/replay.

  Options (optional):
    * `:trace_file` – trace file path for this GenServer. If not set, defaults to the module name (dots → underscores, lowercased) + `.json`, e.g. `Replayx.Examples.CrashingGenServer` → `"replayx_examples_crashinggenserver.json"`.
    * `:trace_buffer_size` – number of events (and state snapshots) to keep in a ring buffer for crash debugging. On crash, the buffer is flushed to the trace file. Default is 10.

  In init, put `replayx_recorder` or `replayx_replayer` in your state so that
  callbacks can record or consume from the trace. For record: pass the recorder
  pid in start_link's init args and call `Replayx.Recorder.monitor(recorder_pid, self())`
  so that on crash the last N events (and state snapshots) are flushed to the trace file.
  For replay, the Replayer passes `{:replayx_replayer, agent_pid}`.

  In your callbacks, use `Replayx.Clock` and `Replayx.Rand` instead of `System`
  and `:rand` so that time and randomness are recorded/replayed.
  """

  @doc false
  defmacro __using__(opts) do
    explicit_trace_file = Keyword.get(opts || [], :trace_file)
    buffer_size = Keyword.get(opts || [], :trace_buffer_size, 10)

    quote do
      use GenServer

      @doc false
      def __replayx_trace_file__ do
        case unquote(explicit_trace_file) do
          nil ->
            __MODULE__
            |> to_string()
            |> String.replace_prefix("Elixir.", "")
            |> String.downcase()
            |> String.replace(".", "_")
            |> Kernel.<>(".json")

          path ->
            path
        end
      end

      @doc false
      def __replayx_trace_buffer_size__ do
        unquote(buffer_size)
      end

      def handle_call(msg, from, state) do
        Replayx.GenServer.instrument_call(__MODULE__, msg, from, state)
      end

      def handle_cast(msg, state) do
        Replayx.GenServer.instrument_cast(__MODULE__, msg, state)
      end

      def handle_info(msg, state) do
        Replayx.GenServer.instrument_info(__MODULE__, msg, state)
      end

      def handle_call_impl(msg, from, state), do: {:reply, :ok, state}
      def handle_cast_impl(msg, state), do: {:noreply, state}
      def handle_info_impl(msg, state), do: {:noreply, state}

      defoverridable handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     handle_call_impl: 3,
                     handle_cast_impl: 2,
                     handle_info_impl: 2
    end
  end

  @doc false
  @spec instrument_call(module(), term(), term(), term()) :: term()
  def instrument_call(module, msg, from, state) do
    set_process_dict(state)
    maybe_record_message(state, :call, from, msg)
    result = module.handle_call_impl(msg, from, state)
    maybe_record_state_snapshot(state, result, :call)
    result
  end

  @doc false
  @spec instrument_cast(module(), term(), term()) :: term()
  def instrument_cast(module, msg, state) do
    set_process_dict(state)
    maybe_record_message(state, :cast, nil, msg)
    result = module.handle_cast_impl(msg, state)
    maybe_record_state_snapshot(state, result, :cast)
    result
  end

  @doc false
  @spec instrument_info(module(), term(), term()) :: term()
  def instrument_info(module, msg, state) do
    set_process_dict(state)
    maybe_record_message(state, :info, nil, msg)
    result = module.handle_info_impl(msg, state)
    maybe_record_state_snapshot(state, result, :info)
    result
  end

  defp set_process_dict(state) do
    if recorder = state[:replayx_recorder] do
      Process.put(:replayx_recorder, recorder)
      Process.delete(:replayx_replayer)
    end

    if replayer = state[:replayx_replayer] do
      Process.put(:replayx_replayer, replayer)
      Process.delete(:replayx_recorder)
    end
  end

  defp maybe_record_message(state, kind, from, payload) do
    case state[:replayx_recorder] do
      nil ->
        :ok

      recorder_pid ->
        seq = Replayx.Recorder.next_seq(recorder_pid)
        Replayx.Recorder.record_event(recorder_pid, {:message, seq, kind, from, payload})
    end
  end

  defp maybe_record_state_snapshot(state, result, _kind) do
    case state[:replayx_recorder] do
      nil ->
        :ok

      recorder_pid ->
        new_state = state_from_result(result)

        if new_state != nil,
          do: Replayx.Recorder.record_event(recorder_pid, {:state_snapshot, new_state})
    end
  end

  defp state_from_result({:reply, _reply, new_state}), do: new_state
  defp state_from_result({:reply, _reply, new_state, _timeout}), do: new_state
  defp state_from_result({:noreply, new_state}), do: new_state
  defp state_from_result({:noreply, new_state, _timeout}), do: new_state
  defp state_from_result({:stop, _reason, _reply, new_state}), do: new_state
  defp state_from_result({:stop, _reason, new_state}), do: new_state
  defp state_from_result(_), do: nil
end
