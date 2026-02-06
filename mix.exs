defmodule Replayx.MixProject do
  use Mix.Project

  def project do
    [
      app: :replayx,
      version: "1.0.2",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: dialyzer(),
      description:
        "Deterministic replay debugging for Elixir GenServers. Record what led to a crash, then replay it exactly.",
      package: package(),
      docs: docs()
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/SumitPugalia/replayx",
        "Docs" => "https://hexdocs.pm/replayx"
      },
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "Replayx",
      name: "Replayx",
      source_url: "https://github.com/SumitPugalia/replayx",
      source_ref: "v#{Mix.Project.config()[:version]}",
      extras: ["README.md": [filename: "README.md", title: "Overview"]],
      groups_for_modules: [
        "Public API": [
          Replayx,
          Replayx.Clock,
          Replayx.Rand,
          Replayx.GenServer,
          Replayx.TracedServerStarter
        ],
        "Recording & replay": [Replayx.Recorder, Replayx.Replayer, Replayx.ReplayerState],
        "Trace format": [Replayx.Trace],
        "Mix tasks": [Mix.Tasks.Replay, Mix.Tasks.Replay.Record]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:jason, :mix],
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      optional_applications: [:telemetry]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"},
      {:stream_data, "~> 1.0", only: [:test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
