defmodule Mix.Tasks.Git.InstallHooks do
  @shortdoc "Installs the git pre-push hook (format, credo, dialyzer, test)"
  @moduledoc """
  Copies `script/pre-push` to `.git/hooks/pre-push` and makes it executable.

  After running this, `git push` will run format, credo, dialyzer, and tests.
  If any check fails, the push is aborted.

      mix git.install_hooks
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    root = File.cwd!()
    source = Path.join(root, "script/pre-push")
    hooks_dir = Path.join(root, ".git/hooks")
    dest = Path.join(hooks_dir, "pre-push")

    unless File.exists?(source) do
      Mix.raise("script/pre-push not found. Run from project root.")
    end

    File.mkdir_p!(hooks_dir)
    File.cp!(source, dest)
    File.chmod!(dest, 0o755)

    Mix.shell().info("Installed git pre-push hook at .git/hooks/pre-push")
    Mix.shell().info("git push will now run: format, credo, dialyzer, test")
  end
end
