defmodule MingaGitExtended.UI.Picker.GitStashSourceTest do
  @moduledoc "Tests for the git stash picker source."
  use ExUnit.Case, async: true

  alias Minga.Git.StashEntry
  alias Minga.Git.Stub, as: GitStub
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Extension.Picker.Item
  alias MingaGitExtended.UI.Picker.GitStashSource

  @moduletag :tmp_dir

  describe "candidates" do
    test "formats stash entries from the requested repository", %{tmp_dir: dir} do
      GitStub.set_stashes(dir, [
        %StashEntry{index: 0, ref: "stash@{0}", date: "2 minutes ago", message: "WIP on main"}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      assert {:ok, [%Item{id: 0} = item], :done} = GitStashSource.candidates({dir, :list}, :start)
      assert item.label == "WIP on main"
      assert item.description == "2 minutes ago"
      assert item.annotation == "stash@{0}"
    end
  end

  describe "selection" do
    test "list mode reports the selected stash message", %{tmp_dir: dir} do
      state = test_state()
      item = %Item{id: 0, label: "WIP on main"}

      result = GitStashSource.on_select(state, item, {dir, :list})
      assert result.shell_runtime.state.notice.message == "Stash: WIP on main"
    end

    test "drop mode drops the selected stash", %{tmp_dir: dir} do
      GitStub.set_stashes(dir, [
        %StashEntry{index: 0, ref: "stash@{0}", date: "2 minutes ago", message: "WIP on main"},
        %StashEntry{index: 1, ref: "stash@{1}", date: "1 hour ago", message: "WIP on feature"}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      state = test_state()
      item = %Item{id: 1, label: "WIP on feature"}

      result = GitStashSource.on_select(state, item, {dir, :drop})
      assert result.shell_runtime.state.notice.message == "Dropped stash@{1}"
      assert {:ok, [%StashEntry{message: "WIP on main"}]} = GitStub.stash_list(dir)
    end

    test "drop action is available from list mode", %{tmp_dir: dir} do
      GitStub.set_stashes(dir, [
        %StashEntry{index: 0, ref: "stash@{0}", date: "2 minutes ago", message: "WIP on main"}
      ])

      on_exit(fn -> GitStub.clear(dir) end)

      item = %Item{id: 0, label: "WIP on main"}
      args = {dir, :list}

      assert GitStashSource.actions(item, args) == [{"Drop", :drop}]

      result = GitStashSource.on_action(test_state(), :drop, item, args)
      assert result.shell_runtime.state.notice.message == "Dropped stash@{0}"
    end
  end

  defp test_state do
    %EditorState{
      workspace: %MingaEditor.Session.State{}
    }
  end
end
