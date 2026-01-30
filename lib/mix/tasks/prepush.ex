defmodule Mix.Tasks.Prepush do
  @shortdoc "Runs format, credo, dialyzer, and tests (same as pre-push hook)"
  @moduledoc """
  Runs the same checks as the pre-push hook:

    * mix format --check-formatted
    * mix credo
    * mix dialyzer
    * mix test

  Use before pushing or install the hook:

      cp script/pre-push .git/hooks/pre-push && chmod +x .git/hooks/pre-push
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Project.get!()

    run_check("format --check-formatted", &run_format/0)
    run_check("credo", &run_credo/0)
    run_check("dialyzer", &run_dialyzer/0)
    run_check("test", &run_test/0)

    Mix.shell().info("")
    Mix.shell().info("Pre-push checks passed.")
  end

  defp run_check(name, fun) do
    Mix.shell().info("==> mix #{name}")
    fun.()
  end

  defp run_format do
    Mix.Task.run("format", ["--check-formatted"])
  end

  defp run_credo do
    Mix.Task.run("credo", [])
  end

  defp run_dialyzer do
    Mix.Task.run("dialyzer", [])
  end

  defp run_test do
    # Run in test environment (prepush runs in dev by default)
    {output, exit_code} = System.cmd("mix", ["test"], env: [{"MIX_ENV", "test"}])
    IO.write(output)
    if exit_code != 0, do: Mix.raise("mix test failed with exit code #{exit_code}")
  end
end
