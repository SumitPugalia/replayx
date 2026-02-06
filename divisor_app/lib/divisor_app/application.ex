defmodule DivisorApp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DivisorAppWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:divisor_app, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DivisorApp.PubSub},
      # DynamicSupervisor for Replayx-traced workers (DivisorGenServer)
      {DynamicSupervisor, strategy: :one_for_one, name: DivisorApp.TracedWorkers},
      # Start DivisorGenServer under TracedServerStarter (record/replay on crash)
      DivisorApp.DivisorServerStarter,
      DivisorAppWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DivisorApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DivisorAppWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
