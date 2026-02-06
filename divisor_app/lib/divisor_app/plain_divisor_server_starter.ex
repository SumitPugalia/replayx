defmodule DivisorApp.PlainDivisorServerStarter do
  @moduledoc """
  Starts the PlainDivisorGenServer under the app's DynamicSupervisor via Replayx.TracedServerStarter.
  Same pattern as DivisorServerStarter but for the plain example (route /divide_plain).
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init(_opts) do
    _ = Replayx.TracedServerStarter.start_child(
      DivisorApp.PlainTracedWorkers,
      DivisorApp.PlainDivisorGenServer,
      [],
      name: DivisorApp.PlainDivisorGenServer
    )

    {:ok, %{}}
  end
end
