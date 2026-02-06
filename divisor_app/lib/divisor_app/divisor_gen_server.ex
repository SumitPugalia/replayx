defmodule DivisorApp.DivisorGenServer do
  @moduledoc """
  GenServer that divides 10 by a divisor. Crashes on division by zero.
  Started under DynamicSupervisor via Replayx.TracedServerStarter; all messages
  are recorded so you can replay after a crash.
  """
  use Replayx.GenServer, trace_buffer_size: 50, virtualize: true

  def start_link(recorder_pid) when is_pid(recorder_pid) do
    GenServer.start_link(__MODULE__, [recorder_pid], [])
  end

  def init_impl(_args), do: {:ok, %{divisions: 0, last_divisor: nil}}

  def handle_call_impl({:divide, divisor}, _from, state) do
    result = div(10, divisor)
    new_state = %{state | divisions: state.divisions + 1, last_divisor: divisor}
    {:reply, {:ok, result}, new_state}
  end

  def handle_call_impl(:state, _from, state), do: {:reply, state, state}
  def handle_call_impl(_msg, _from, state), do: {:reply, :ignored, state}

  def handle_cast_impl(_msg, state), do: {:noreply, state}

  def handle_info_impl({:divide, divisor}, state) do
    _result = div(10, divisor)
    {:noreply, %{state | divisions: state.divisions + 1, last_divisor: divisor}}
  end

  def handle_info_impl(_msg, state), do: {:noreply, state}
end
