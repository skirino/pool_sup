defmodule PoolSup.Mixfile do
  use Mix.Project

  @github_url "https://github.com/skirino/pool_sup"

  def project() do
    [
      app:             :pool_sup,
      version:         "0.5.0",
      elixir:          "~> 1.5",
      build_embedded:  Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps:            deps(),
      description:     "A supervisor specialized to manage pool of workers",
      package:         package(),
      source_url:      @github_url,
      homepage_url:    @github_url,
      test_coverage:   [tool: Coverex.Task, coveralls: true],
    ]
  end

  def application() do
    []
  end

  defp deps() do
    [
      {:croma  , "~> 0.9"},
      {:dialyze, "~> 0.2" , only: :dev},
      {:ex_doc , "~> 0.18", only: :dev},
      {:coverex, "~> 1.4" , only: :test},
    ]
  end

  defp package() do
    [
      files:       ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Shunsuke Kirino"],
      licenses:    ["MIT"],
      links:       %{"GitHub repository" => @github_url},
    ]
  end
end
