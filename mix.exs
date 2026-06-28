defmodule MiniAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :mini_agent,
      version: "0.8.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      escript: [main_module: MiniAgent.CLI],
      dialyzer: [plt_add_apps: [:mix], ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  def application do
    [
      mod: {MiniAgent.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
