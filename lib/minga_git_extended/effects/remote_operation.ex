defmodule MingaGitExtended.Effects.RemoteOperation do
  @moduledoc "Runs a remote Git action against the repository captured by its command or retry."
  @behaviour MingaEditor.Extension.RepositoryJob.Handler

  alias Minga.Git
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.GitFeedback
  alias MingaEditor.Extension.RepositoryJob

  @type operation :: :push | :pull | :fetch | :pull_and_retry
  @typep args :: {operation(), module()}
  @typep command_result :: EditorAPI.state() | {:schedule, EditorAPI.state(), RepositoryJob.t()}

  @spec propose(EditorAPI.state(), String.t(), operation(), module()) :: command_result()
  def propose(state, root, operation, git \\ Git) do
    case RepositoryJob.propose(state, :remote, root, __MODULE__, {operation, git}) do
      {:ok, job} ->
        {:schedule, state, job}

      {:error, reason} ->
        EditorAPI.notice(state, "Git operation not scheduled: #{inspect(reason)}")
    end
  end

  @impl true
  @spec run(String.t(), args()) :: {:ok, :ok} | {:error, term()}
  def run(root, {operation, git}) do
    case perform(root, operation, git) do
      :ok -> {:ok, :ok}
      {:error, _reason} = error -> error
    end
  after
    git.refresh_status(root)
  end

  @impl true
  @spec on_start(EditorAPI.state(), String.t(), args()) :: EditorAPI.state()
  def on_start(state, _root, {operation, _git}),
    do: GitFeedback.progress(state, progress_message(operation))

  @impl true
  @spec on_result(EditorAPI.state(), String.t(), RepositoryJob.Handler.outcome(), args()) ::
          EditorAPI.state()
  def on_result(state, _root, {:completed, :ok}, {operation, _git}),
    do: GitFeedback.publish(state, success_message(operation), :success)

  def on_result(state, root, {:failed, :timeout}, {operation, git}) do
    git.refresh_status(root)
    GitFeedback.publish(state, "#{operation_name(operation)} timed out", :error)
  end

  def on_result(state, root, {:failed, reason}, {operation, git}) do
    message = "#{operation_name(operation)} failed: #{format_reason(reason)}"
    retry = retry_job(state, root, operation, reason, git)
    GitFeedback.publish(state, message, :error, retry)
  end

  def on_result(state, root, {:canceled, _reason}, {_operation, git}) do
    git.refresh_status(root)
    GitFeedback.publish(state, "Git operation canceled", :error)
  end

  @spec perform(String.t(), operation(), module()) :: :ok | {:error, term()}
  defp perform(root, :push, git), do: git.push(root)
  defp perform(root, :pull, git), do: git.pull(root)
  defp perform(root, :fetch, git), do: git.fetch_remotes(root)

  defp perform(root, :pull_and_retry, git) do
    case git.pull(root) do
      :ok -> git.push(root)
      {:error, reason} -> {:error, "pull failed: #{format_reason(reason)}"}
    end
  end

  @spec retry_job(EditorAPI.state(), String.t(), operation(), term(), module()) ::
          RepositoryJob.t() | nil
  defp retry_job(state, root, :push, reason, git) when is_binary(reason) do
    if String.contains?(String.downcase(reason), [
         "non-fast-forward",
         "fetch first",
         "remote contains work",
         "tip of your current branch is behind"
       ]) do
      case RepositoryJob.propose(state, :remote, root, __MODULE__, {:pull_and_retry, git}) do
        {:ok, job} -> job
        {:error, _reason} -> nil
      end
    end
  end

  defp retry_job(_state, _root, _operation, _reason, _git), do: nil

  @spec format_reason(term()) :: String.t()
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  @spec progress_message(operation()) :: String.t()
  defp progress_message(:push), do: "Pushing…"
  defp progress_message(:pull), do: "Pulling…"
  defp progress_message(:fetch), do: "Fetching…"
  defp progress_message(:pull_and_retry), do: "Pulling and retrying…"

  @spec success_message(operation()) :: String.t()
  defp success_message(:push), do: "Pushed"
  defp success_message(:pull), do: "Pulled"
  defp success_message(:fetch), do: "Fetched"
  defp success_message(:pull_and_retry), do: "Pushed"

  @spec operation_name(operation()) :: String.t()
  defp operation_name(:push), do: "Push"
  defp operation_name(:pull), do: "Pull"
  defp operation_name(:fetch), do: "Fetch"
  defp operation_name(:pull_and_retry), do: "Pull and retry"
end
