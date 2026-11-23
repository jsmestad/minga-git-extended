defmodule MingaGitExtended.MixProject do
  use Mix.Project

  @source_url "https://github.com/jsmestad/minga-git-extended"

  def project do
    [
      app: :minga_git_extended,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: false,
      deps: deps(Mix.env()),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: [test: ["test --no-start --warnings-as-errors"]],
      description: "Git workflows for the Minga editor",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps(:test) do
    case System.get_env("MINGA_HOST_SOURCE") do
      nil ->
        Mix.raise(
          "Set MINGA_HOST_SOURCE to a compatible Minga checkout to run integration tests."
        )

      root ->
        [{:minga, path: Path.expand(root), only: :test}]
    end
  end

  defp deps(_env) do
    sdk =
      case System.get_env("MINGA_SDK_PATH") do
        nil -> {:minga_sdk, "~> 0.1.2", only: :dev, runtime: false}
        path -> {:minga_sdk, path: Path.expand(path), only: :dev, runtime: false}
      end

    [sdk, {:ex_doc, "~> 0.40", only: :dev, runtime: false}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
