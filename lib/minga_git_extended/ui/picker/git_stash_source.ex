defmodule MingaGitExtended.UI.Picker.GitStashSource do
  @moduledoc "Lists and drops stashes from an explicit Git repository."
  @behaviour MingaEditor.Extension.Picker.Source

  alias Minga.Git
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Picker.Item
  alias MingaEditor.Extension.Picker.Source

  @typedoc "The absolute repository root and the default action on selection."
  @type args :: {Path.t(), :list | :drop}

  @impl true
  @spec title() :: String.t()
  def title, do: "Git Stashes"

  @impl true
  @spec candidates(args(), :start) :: {:ok, [Item.t()], :done} | {:error, String.t()}
  def candidates({root, _action}, :start) do
    with {:ok, entries} <- Git.stash_list(root) do
      {:ok, Enum.map(entries, &format_entry/1), :done}
    end
  end

  @impl true
  @spec on_select(EditorAPI.state(), Item.t(), args()) :: EditorAPI.state()
  def on_select(state, %Item{id: index}, {root, :drop}), do: drop_stash(state, root, index)

  def on_select(state, %Item{label: label}, {_root, :list}),
    do: EditorAPI.notice(state, "Stash: #{label}")

  @impl true
  @spec actions(Item.t(), args()) :: [Source.action_entry()]
  def actions(_item, _args), do: [{"Drop", :drop}]

  @impl true
  @spec on_action(EditorAPI.state(), :drop, Item.t(), args()) :: EditorAPI.state()
  def on_action(state, :drop, %Item{id: index}, {root, _action}),
    do: drop_stash(state, root, index)

  @spec format_entry(Git.stash_entry()) :: Item.t()
  defp format_entry(entry) do
    %Item{
      id: entry.index,
      label: entry.message,
      description: entry.date,
      annotation: entry.ref
    }
  end

  @spec drop_stash(EditorAPI.state(), Path.t(), non_neg_integer()) :: EditorAPI.state()
  defp drop_stash(state, root, index) do
    case Git.stash_drop(root, index) do
      :ok ->
        Git.refresh_status(root)
        EditorAPI.notice(state, "Dropped stash@{#{index}}")

      {:error, reason} ->
        EditorAPI.notice(state, "Drop stash failed: #{reason}")
    end
  end
end
