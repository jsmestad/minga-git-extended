defmodule MingaGitExtended.UI.Picker.GitBranchSourceTest do
  @moduledoc "Tests branch picker branch-management actions."
  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaGitExtended.UI.Picker.GitBranchSource
  alias MingaEditor.Extension.Picker.Item

  test "local branch items expose a delete action" do
    item = %Item{id: {:branch, "feature", false, false}, label: "feature"}

    assert [{"Delete", :delete}] = GitBranchSource.actions(item, "/repo")
  end

  test "current and remote branch items do not expose delete actions" do
    current = %Item{id: {:branch, "main", true, false}, label: "main"}
    remote = %Item{id: {:branch, "origin/main", false, true}, label: "origin/main"}

    assert GitBranchSource.actions(current, "/repo") == []
    assert GitBranchSource.actions(remote, "/repo") == []
  end

  test "Ctrl-D offers delete for a local branch but never for a remote branch" do
    local = %Item{id: {:branch, "feature", false, false}, label: "feature"}
    remote = %Item{id: {:branch, "origin/feature", false, true}, label: "origin/feature"}

    assert GitBranchSource.shortcut_action(local, {:ctrl, ?d}, "/repo") == :delete
    assert GitBranchSource.shortcut_action(remote, {:ctrl, ?d}, "/repo") == nil
  end

  test "delete action on current branch reports an error without entering confirmation" do
    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %SessionState{}
    }

    item = %Item{id: {:branch, "main", true, false}, label: "main"}

    result = GitBranchSource.on_action(state, :delete, item, "/repo")

    assert result.shell_runtime.state.notice.message == "Cannot delete current branch"
    assert result.workspace.editing.mode == :normal
  end
end
