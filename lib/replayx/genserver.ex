defmodule Replayx.GenServer do
  @moduledoc """
  Instrumented GenServer that records or replays messages, time, and randomness.
  Use this instead of `use GenServer` when you want record/replay.

  In init, put `replayx_recorder` or `replayx_replayer` in your state so that
  callbacks can record or consume from the trace. For record: pass
  `{:replayx_recorder, recorder_pid}` in start_link's init args. For replay,
  the Replayer passes `{:replayx_replayer, agent_pid}`.

  In your callbacks, use `Replayx.Clock` and `Replayx.Rand` instead of `System`
  and `:rand` so that time and randomness are recorded/replayed.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      use GenServer

      @behaviour GenServer

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
  def instrument_call(module, msg, from, state) do
    set_process_dict(state)
    maybe_record_message(state, :call, from, msg)
    module.handle_call_impl(msg, from, state)
  end

  @doc false
  def instrument_cast(module, msg, state) do
    set_process_dict(state)
    maybe_record_message(state, :cast, nil, msg)
    module.handle_cast_impl(msg, state)
  end

  @doc false
  def instrument_info(module, msg, state) do
    set_process_dict(state)
    maybe_record_message(state, :info, nil, msg)
    module.handle_info_impl(msg, state)
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
end
