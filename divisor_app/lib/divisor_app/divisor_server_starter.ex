defmodule DivisorApp.DivisorServerStarter do
  @moduledoc """
  Starts the DivisorGenServer under the app's DynamicSupervisor via Replayx.TracedServerStarter.
  Runs once at application start so the divisor server is available for web requests.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, [])
  end

  @impl true
  def init(_opts) do
    _ = Replayx.TracedServerStarter.start_child(
      DivisorApp.TracedWorkers,
      DivisorApp.DivisorGenServer,
      [],
      name: DivisorApp.DivisorGenServer
    )

    {:ok, %{}}
  end
end
