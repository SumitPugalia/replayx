defmodule DivisorApp.PlainDivisorGenServer do
  @moduledoc """
  Same divide logic as DivisorGenServer but started as a separate (plain) example.
  Used by the /divide_plain route. Traces go to a different file for replay:
  `mix replay DivisorApp.PlainDivisorGenServer`
  """
  use Replayx.GenServer,
    trace_buffer_size: 50,
    virtualize: true,
    trace_file: "plain_divisor_gen_server.json"

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
