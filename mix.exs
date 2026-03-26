defmodule Instantgrep.MixProject do
  use Mix.Project

  def project do
    [
      app: :instantgrep,
      version: "0.0.5",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      dialyzer: [plt_add_apps: [:mix]],
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp escript do
    [main_module: Instantgrep.CLI, name: "instantgrep-daemon"]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      quality: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
