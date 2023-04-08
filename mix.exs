defmodule PoolSup.Mixfile do
  use Mix.Project

  @github_url "https://github.com/skirino/pool_sup"

  def project() do
    [
      app:               :pool_sup,
      version:           "0.6.1",
      elixir:            "~> 1.6",
      build_embedded:    Mix.env() == :prod,
      start_permanent:   Mix.env() == :prod,
      deps:              deps(),
      description:       "A supervisor specialized to manage pool of workers",
      package:           package(),
      source_url:        @github_url,
      homepage_url:      @github_url,
      test_coverage:     [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.detail": :test, "coveralls.post": :test, "coveralls.html": :test],
    ]
  end

  def application() do
    []
  end

  defp deps() do
    [
      {:croma      , "~> 0.9"},
      {:dialyxir   , "~> 1.3" , [only: :dev , runtime: false]},
      {:ex_doc     , "~> 0.29", [only: :dev , runtime: false]},
      {:excoveralls, "~> 0.16", [only: :test, runtime: false]},
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
