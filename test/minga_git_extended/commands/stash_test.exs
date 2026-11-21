defmodule MingaGitExtended.CommandsStashTest do
  @moduledoc "Tests for the git stash editor commands."
  use ExUnit.Case, async: true

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias Minga.Git.Repo
  alias Minga.Git.StashEntry
  alias Minga.Git.StatusEntry
  alias Minga.Git.Stub, as: GitStub
  alias MingaGitExtended.Commands, as: GitCommands
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State.FileTree
  alias MingaGitExtended.UI.Picker.GitStashSource

  @moduletag :tmp_dir
  @source {:extension, :git_extended_stash_test}

  setup %{tmp_dir: dir} do
    GitStub.set_root(dir, dir)
    on_exit(fn -> GitStub.clear(dir) end)
    {:ok, root: dir}
  end

  describe "stash save/pop" do
    test "save success clears the repo and reports success", %{root: dir} do
      repo = start_repo(dir, [tracked_change()], [])

      result = GitCommands.execute(build_state(dir), :git_stash_save)
      Repo.await_refresh(repo)

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(result) == "Stashed changes"
      assert Repo.status(repo) == []

      summary = Repo.summary(repo)
      assert summary.staged_count == 0
      assert summary.unstaged_count == 0
      assert summary.untracked_count == 0
      assert summary.conflict_count == 0
      assert summary.stash_count == 1
    end

    test "save with no changes reports a no-op", %{root: dir} do
      repo = start_repo(dir, [], [])

      result = GitCommands.execute(build_state(dir), :git_stash_save)
      Repo.await_refresh(repo)

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(result) == "No changes to stash"
      assert Repo.summary(repo).stash_count == 0
    end

    test "pop restores the stashed repo status", %{root: dir} do
      repo = start_repo(dir, [tracked_change()], [])

      save_result = GitCommands.execute(build_state(dir), :git_stash_save)
      Repo.await_refresh(repo)

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(save_result) ==
               "Stashed changes"

      assert Repo.status(repo) == []
      assert Repo.summary(repo).stash_count == 1

      pop_result = GitCommands.execute(build_state(dir), :git_stash_pop)
      Repo.await_refresh(repo)

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(pop_result) == "Popped stash"
      assert Repo.status(repo) == [tracked_change()]

      summary = Repo.summary(repo)
      assert summary.staged_count == 0
      assert summary.unstaged_count == 1
      assert summary.untracked_count == 0
      assert summary.conflict_count == 0
      assert summary.stash_count == 0
    end

    test "pop failure reports the backend error", %{root: dir} do
      start_repo(dir, [], [])

      result = GitCommands.execute(build_state(dir), :git_stash_pop)

      assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(result) ==
               "Stash pop failed: No stash entries to pop"
    end
  end

  describe "stash picker commands" do
    setup do
      :ok = CodeLease.activate_source(@source, [GitCommands, GitStashSource])

      on_exit(fn ->
        {:ok, token} = CodeLease.quiesce_source(@source)
        :ok = CodeLease.complete_unload(token)
      end)
    end

    test "list opens the stash picker", %{root: dir} do
      GitStub.set_stashes(dir, [stash_entry(0)])

      result = open_picker(dir, :git_stash_list)

      assert {:picker, %{picker_ui: %{source: GitStashSource}}} =
               MingaEditor.Shell.Runtime.state(result.shell_runtime).modal
    end

    test "drop opens the stash picker in drop mode", %{root: dir} do
      GitStub.set_stashes(dir, [stash_entry(0)])

      result = open_picker(dir, :git_stash_drop)

      assert {:picker, %{picker_ui: %{source: GitStashSource, extension: %{args: {^dir, :drop}}}}} =
               MingaEditor.Shell.Runtime.state(result.shell_runtime).modal
    end
  end

  defp open_picker(root, command) do
    {:ok, state} =
      CallbackInvoker.invoke(@source, GitCommands, :execute, [build_state(root), command], :test)

    state
  end

  defp build_state(root) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace:
        SessionState.set_file_tree(%SessionState{}, FileTree.set_project_root(%FileTree{}, root))
    }
  end

  defp start_repo(dir, status_entries, stashes) do
    GitStub.set_status(dir, status_entries)
    GitStub.set_stashes(dir, stashes)
    start_supervised!({Repo, git_root: dir}, id: {Repo, dir})
  end

  defp tracked_change do
    %StatusEntry{path: "file.txt", status: :modified, staged: false}
  end

  defp stash_entry(index) do
    %StashEntry{index: index, ref: "stash@{#{index}}", date: "1 minute ago", message: "WIP"}
  end
end
