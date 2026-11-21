defmodule MingaGitExtended.Effects.CommitMessageGeneration do
  @moduledoc "Generates a commit message from the staged diff of the captured repository."
  @behaviour MingaEditor.Extension.RepositoryJob.Handler

  alias Minga.Git
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.RepositoryJob
  alias MingaGitExtended.Git.CommitMessageGenerator
  alias MingaGitExtended.UI.Prompt.GitCommit

  @typep dependencies :: {module(), module()}
  @type command_result :: EditorAPI.state() | {:schedule, EditorAPI.state(), RepositoryJob.t()}

  @spec propose(EditorAPI.state(), String.t(), dependencies()) :: command_result()
  def propose(state, root, dependencies \\ {Git, CommitMessageGenerator}) do
    case RepositoryJob.propose(state, :commit_message, root, __MODULE__, dependencies) do
      {:ok, job} ->
        {:schedule, state, job}

      {:error, reason} ->
        EditorAPI.notice(state, "Commit message not scheduled: #{inspect(reason)}")
    end
  end

  @impl true
  @spec run(String.t(), dependencies()) :: {:ok, String.t()} | {:error, String.t()}
  def run(root, {git, generator}) do
    case git.diff(root, staged: true) do
      {:ok, ""} -> {:error, "Nothing staged to generate a message for"}
      {:ok, diff} -> generator.generate(diff)
      {:error, reason} -> {:error, "Failed to read staged diff: #{reason}"}
    end
  end

  @impl true
  @spec on_start(EditorAPI.state(), String.t(), dependencies()) :: EditorAPI.state()
  def on_start(state, _root, _args), do: EditorAPI.notice(state, "Generating commit message…")

  @impl true
  @spec on_result(EditorAPI.state(), String.t(), RepositoryJob.Handler.outcome(), dependencies()) ::
          EditorAPI.state()
  def on_result(state, root, {:completed, message}, _args) when is_binary(message),
    do: GitCommit.suggest(state, root, message)

  def on_result(state, _root, {:failed, :timeout}, _args),
    do: EditorAPI.notice(state, "Commit message generation timed out")

  def on_result(state, _root, {:failed, reason}, _args) when is_binary(reason),
    do: EditorAPI.notice(state, reason)

  def on_result(state, _root, {:failed, reason}, _args),
    do: EditorAPI.notice(state, "Commit message generation failed: #{inspect(reason)}")

  def on_result(state, _root, {:canceled, _reason}, _args),
    do: EditorAPI.notice(state, "Commit message generation canceled")
end
