defmodule MingaGitExtended.UI.Prompt.GitCommit do
  @moduledoc "Submits a commit or amend against the repository captured when the prompt opened."

  @behaviour MingaEditor.Extension.Prompt.Handler

  alias Minga.Git
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Prompt

  @type variant :: :commit | :amend

  @spec open(EditorAPI.state(), String.t(), variant(), String.t()) :: EditorAPI.state()
  def open(state, root, variant, default) do
    case Prompt.text(state, __MODULE__, {root, variant},
           label: label(variant),
           default: default
         ) do
      {:ok, updated} -> updated
      {:error, reason} -> EditorAPI.notice(state, "Could not open Git prompt: #{inspect(reason)}")
    end
  end

  @spec suggest(EditorAPI.state(), String.t(), String.t()) :: EditorAPI.state()
  def suggest(state, root, message) do
    case Prompt.text(state, __MODULE__, {root, :commit},
           label: label(:commit),
           default: message,
           admission: :if_idle
         ) do
      {:ok, updated} ->
        EditorAPI.notice(updated, "Commit message generated")

      {:error, :modal_busy} ->
        EditorAPI.notice(state, "Commit message ready (prompt already open)")

      {:error, reason} ->
        EditorAPI.notice(state, "Could not open Git prompt: #{inspect(reason)}")
    end
  end

  @impl true
  @spec on_submit(EditorAPI.state(), String.t(), {String.t(), variant()}) :: EditorAPI.state()
  def on_submit(state, text, {root, variant}) do
    case String.trim(text) do
      "" -> EditorAPI.notice(state, empty_message(variant))
      message -> submit(state, root, variant, message)
    end
  end

  @spec submit(EditorAPI.state(), String.t(), variant(), String.t()) :: EditorAPI.state()
  defp submit(state, root, variant, message) do
    case Git.commit(root, message, amend: variant == :amend) do
      {:ok, hash} ->
        Git.refresh_status(root)
        EditorAPI.notice(state, "#{completed(variant)} #{hash}")

      {:error, reason} ->
        EditorAPI.notice(state, "#{failure(variant)}: #{reason}")
    end
  end

  @spec label(variant()) :: String.t()
  defp label(:commit), do: "Commit message: "
  defp label(:amend), do: "Amend message: "

  @spec completed(variant()) :: String.t()
  defp completed(:commit), do: "Committed"
  defp completed(:amend), do: "Amended"

  @spec failure(variant()) :: String.t()
  defp failure(:commit), do: "Commit failed"
  defp failure(:amend), do: "Amend failed"

  @spec empty_message(variant()) :: String.t()
  defp empty_message(:commit), do: "Commit cancelled: empty message"
  defp empty_message(:amend), do: "Amend aborted: empty message"
end
