defmodule MingaGitExtended.UI.Picker.GitBranchSource do
  @moduledoc "Lists local and remote branches for checkout, creation, and deletion."
  @behaviour MingaEditor.Extension.Picker.Source

  alias Minga.Git
  alias Minga.Git.BranchInfo
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Picker.Item
  alias MingaEditor.Extension.Picker.Source
  alias MingaGitExtended.UI.Prompt.BranchDelete

  @typedoc "The absolute repository root."
  @type args :: Path.t()

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch Branch"

  @impl true
  @spec candidates(args(), :start) :: {:ok, [Item.t()], :done} | {:error, String.t()}
  def candidates(root, :start) do
    with {:ok, branches} <- Git.branch_list(root) do
      {local, remote} = Enum.split_with(branches, fn branch -> not branch.remote end)
      {:ok, Enum.map(local ++ remote, &format_branch/1), :done}
    end
  end

  @impl true
  @spec fallback(String.t(), args()) :: Item.t() | nil
  def fallback(query, _root) do
    case String.trim(query) do
      "" -> nil
      name -> %Item{id: {:create, name}, label: "Create branch #{name}"}
    end
  end

  @impl true
  @spec on_select(EditorAPI.state(), Item.t(), args()) :: EditorAPI.state()
  def on_select(state, %Item{id: {:create, name}}, root) do
    branch_result(state, root, Git.branch_create(root, name), "Created and switched to #{name}")
  end

  def on_select(state, %Item{id: {:branch, name, _current?, _remote?}}, root) do
    branch_result(state, root, Git.branch_switch(root, name), "Switched to #{name}")
  end

  @impl true
  @spec actions(Item.t(), args()) :: [Source.action_entry()]
  def actions(%Item{id: {:branch, _name, false, false}}, _root), do: [{"Delete", :delete}]
  def actions(_item, _root), do: []

  @impl true
  @spec on_action(EditorAPI.state(), :delete, Item.t(), args()) :: EditorAPI.state()
  def on_action(state, :delete, %Item{id: {:branch, _name, true, false}}, _root),
    do: EditorAPI.notice(state, "Cannot delete current branch")

  def on_action(state, :delete, %Item{id: {:branch, name, false, false}}, root),
    do: BranchDelete.open(state, root, name)

  @spec branch_result(EditorAPI.state(), args(), :ok | {:error, String.t()}, String.t()) ::
          EditorAPI.state()
  defp branch_result(state, root, :ok, message) do
    Git.refresh_status(root)
    EditorAPI.notice(state, message)
  end

  defp branch_result(state, _root, {:error, reason}, _message),
    do: EditorAPI.notice(state, "Failed: #{reason}")

  @spec format_branch(BranchInfo.t()) :: Item.t()
  defp format_branch(branch) do
    %Item{
      id: {:branch, branch.name, branch.current, branch.remote},
      label: branch.name,
      description: branch_description(branch),
      annotation: branch_annotation(branch)
    }
  end

  @spec branch_annotation(BranchInfo.t()) :: String.t() | nil
  defp branch_annotation(%BranchInfo{current: true}), do: "✓"
  defp branch_annotation(%BranchInfo{remote: true}), do: "remote"
  defp branch_annotation(%BranchInfo{}), do: nil

  @spec branch_description(BranchInfo.t()) :: String.t()
  defp branch_description(branch) do
    parts = if branch.behind && branch.behind > 0, do: ["↓#{branch.behind}"], else: []
    parts = if branch.ahead && branch.ahead > 0, do: ["↑#{branch.ahead}" | parts], else: parts
    parts = if branch.upstream, do: ["→ #{branch.upstream}" | parts], else: parts
    Enum.join(parts, " ")
  end
end
