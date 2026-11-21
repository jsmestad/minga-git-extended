defmodule MingaGitExtended.UI.Prompt.BranchDelete do
  @moduledoc "Requires a separate confirmation before force-deleting an unmerged branch."
  @behaviour MingaEditor.Extension.Prompt.Handler

  alias Minga.Git
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Picker
  alias MingaEditor.Extension.Prompt
  alias MingaGitExtended.UI.Picker.GitBranchSource

  @typep target :: {String.t(), String.t(), :delete | :force}

  @spec open(EditorAPI.state(), String.t(), String.t()) :: EditorAPI.state()
  def open(state, root, name), do: ask(state, {root, name, :delete}, "Delete branch #{name}?")

  @impl true
  @spec on_confirm(EditorAPI.state(), Prompt.decision(), target()) :: EditorAPI.state()
  def on_confirm(state, :canceled, {root, _name, _phase}) do
    state
    |> EditorAPI.notice("Branch delete cancelled")
    |> Picker.open(GitBranchSource, root)
  end

  def on_confirm(state, :accepted, {root, name, phase}) do
    case Git.branch_delete(root, name, phase == :force) do
      :ok ->
        Git.refresh_status(root)

        state
        |> EditorAPI.notice("Deleted branch #{name}")
        |> Picker.open(GitBranchSource, root)

      {:error, reason} ->
        failure(state, {root, name, phase}, reason)
    end
  end

  @spec ask(EditorAPI.state(), target(), String.t()) :: EditorAPI.state()
  defp ask(state, target, label) do
    case Prompt.confirm(state, __MODULE__, target, label: label) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        EditorAPI.notice(state, "Could not open confirmation: #{inspect(reason)}")
    end
  end

  @spec failure(EditorAPI.state(), target(), String.t()) :: EditorAPI.state()
  defp failure(state, {root, name, :delete}, reason) do
    if String.contains?(String.downcase(reason), ["not fully merged", "unmerged", "not merged"]) do
      ask(state, {root, name, :force}, "Branch #{name} is not fully merged. Force delete?")
    else
      EditorAPI.notice(state, "Delete failed: #{reason}")
    end
  end

  defp failure(state, {_root, _name, :force}, reason),
    do: EditorAPI.notice(state, "Force delete failed: #{reason}")
end
