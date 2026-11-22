defmodule MingaGitExtended.Input.GitStatusDiffOpenTest do
  @moduledoc "Tests git status diff opening for staged and deleted entries."
  # Registers the GitExtended event callback and configures the shared Git stub.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.CallbackRegistry
  alias Minga.Extension.CodeLease
  alias Minga.Git
  alias Minga.Git.Stub, as: GitStub
  alias MingaEditor.Input.GitStatus
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.GitDiff
  alias MingaEditor.Extension.GitDiff.Target
  alias MingaEditor.GitStatus.Panel, as: GitStatusPanel
  alias MingaEditor.Shell.Traditional.SidebarWorkflow
  alias MingaEditor.State, as: EditorState

  @source {:extension, :minga_git_extended}
  @admission Module.concat(__MODULE__, Admission)
  @none 0
  @effect_timeout 1_000
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    register_git_diff_callback()

    task_supervisor =
      start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: make_ref()))

    scheduler =
      start_supervised!(
        Supervisor.child_spec(
          {EffectScheduler, task_supervisor: task_supervisor, observer: self()},
          id: make_ref()
        )
      )

    :ok = EffectScheduler.attach(scheduler, self())

    on_exit(fn -> GitStub.clear(dir) end)

    {:ok, git_root: dir, scheduler: scheduler}
  end

  test "previewing a staged status entry opens the staged index diff", %{
    git_root: git_root,
    scheduler: scheduler
  } do
    rel_path = "file.txt"
    File.write!(Path.join(git_root, rel_path), "worktree\n")
    GitStub.set_head(git_root, rel_path, "head\n")
    GitStub.set_staged(git_root, rel_path, "staged\n")

    entry = %Git.StatusEntry{path: rel_path, status: :modified, staged: true}
    state = state_with_selected_entry(entry, scheduler, git_root)

    {:handled, state} = GitStatus.handle_key(state, ?p, @none)
    state = receive_effect(state, scheduler)
    active_buf = state.workspace.buffers.active

    assert Buffer.buffer_name(active_buf) == "file.txt [diff:staged]"
    assert buffer_content(active_buf) =~ "staged"
    refute buffer_content(active_buf) =~ "worktree"
  end

  test "previewing a deleted status entry opens a deletion diff without reading the missing file",
       %{git_root: git_root, scheduler: scheduler} do
    rel_path = "deleted.txt"
    GitStub.set_head(git_root, rel_path, "removed\n")
    GitStub.set_staged(git_root, rel_path, :deleted)

    entry = %Git.StatusEntry{path: rel_path, status: :deleted, staged: true}
    state = state_with_selected_entry(entry, scheduler, git_root)

    {:handled, state} = GitStatus.handle_key(state, ?p, @none)
    state = receive_effect(state, scheduler)
    active_buf = state.workspace.buffers.active

    assert Buffer.buffer_name(active_buf) == "deleted.txt [diff:staged]"
    assert buffer_content(active_buf) =~ "removed"
    refute MingaEditor.Shell.Traditional.NoticeWorkflow.message(state) =~ "Could not read"
  end

  test "GUI open diff uses the rendered base path and section when display paths repeat", %{
    git_root: git_root,
    scheduler: scheduler
  } do
    rel_path = "both.txt"
    base = Path.join(git_root, "nested")
    File.mkdir!(base)
    File.write!(Path.join(base, rel_path), "worktree\n")
    GitStub.set_head(git_root, "nested/both.txt", "head\n")
    GitStub.set_staged(git_root, "nested/both.txt", "staged\n")

    staged_entry = %Git.StatusEntry{path: rel_path, status: :modified, staged: true}
    changed_entry = %Git.StatusEntry{path: rel_path, status: :modified, staged: false}

    {:noreply, staged_pending} =
      MingaEditor.handle_info(
        {:minga_input, {:gui_action, {:git_open_diff, rel_path, 0}}},
        state_with_panel_entries([changed_entry, staged_entry], scheduler, git_root, base)
      )

    staged_state = receive_effect(staged_pending, scheduler)
    staged_buf = staged_state.workspace.buffers.active
    assert Buffer.buffer_name(staged_buf) == "both.txt [diff:staged]"
    assert buffer_content(staged_buf) =~ "staged"
    refute buffer_content(staged_buf) =~ "worktree"

    {:noreply, changed_pending} =
      MingaEditor.handle_info(
        {:minga_input, {:gui_action, {:git_open_diff, rel_path, 1}}},
        state_with_panel_entries([staged_entry, changed_entry], scheduler, git_root, base)
      )

    changed_state = receive_effect(changed_pending, scheduler)
    changed_buf = changed_state.workspace.buffers.active
    assert Buffer.buffer_name(changed_buf) == "both.txt [diff:unstaged]"

    assert {:ok, %Target{contents: {"staged\n", "worktree\n"}}} =
             GitDiff.target(changed_state, changed_buf)
  end

  defp register_git_diff_callback do
    callback = MingaGitExtended.Commands
    modules = [callback, MingaGitExtended.DiffActions]
    fingerprint = :crypto.hash(:sha256, Atom.to_string(callback))
    start_supervised!({ArtifactAdmission, name: @admission})

    {:ok, claim} =
      ArtifactAdmission.claim_source_modules(@source, modules, fingerprint,
        server: @admission,
        trusted_application: :minga_git_extended
      )

    :ok = ArtifactAdmission.commit_attempt(claim, server: @admission)
    :ok = CodeLease.activate_source(@source, modules)

    :ok =
      CallbackRegistry.register_extension(:minga_git_extended, [{callback, [:editor_action], []}],
        artifact_admission: @admission
      )

    on_exit(fn ->
      :ok = CallbackRegistry.unregister_source(@source)
      {:ok, token} = CodeLease.quiesce_source(@source)
      :ok = CodeLease.complete_unload(token)
    end)
  end

  defp state_with_selected_entry(entry, scheduler, git_root),
    do: state_with_panel_entries([entry], scheduler, git_root, git_root, :tui)

  defp state_with_panel_entries(entries, scheduler, git_root, entry_base_path, backend \\ :gui) do
    alias MingaEditor.GitStatus.TUIState, as: TuiState

    panel_data = %{
      repo_state: :normal,
      git_root: git_root,
      entry_base_path: entry_base_path,
      branch: "main",
      ahead: 0,
      behind: 0,
      entries: entries
    }

    tui = %TuiState{cursor_index: 1, collapsed: %{}}

    %EditorState{
      effect_scheduler: scheduler,
      frontend: %MingaEditor.State.Frontend{
        port_manager: self(),
        rendering: :disabled,
        backend: backend
      },
      workspace: %MingaEditor.Session.State{keymap_scope: :git_status},
      interaction: %MingaEditor.State.Interaction{}
    }
    |> SidebarWorkflow.replace_git_status(GitStatusPanel.new(panel_data))
    |> SidebarWorkflow.replace_git_status_tui(tui)
  end

  defp receive_effect(state, scheduler) do
    state
    |> apply_next_effect(scheduler, MingaEditor.Extension.EventEffect)
    |> apply_next_effect(scheduler, MingaEditor.Extension.RepositoryJob)
  end

  defp apply_next_effect(state, scheduler, effect) do
    assert_receive {:effect_lifecycle, %Outcome{value: :running} = running}, @effect_timeout
    {:noreply, state} = MingaEditor.handle_info({:effect_lifecycle, running}, state)

    assert_receive {:effect_result, ^scheduler,
                    %Outcome{request: %{effect: %{__struct__: ^effect}}} = outcome},
                   @effect_timeout

    {:noreply, state} = MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)
    state
  end

  defp buffer_content(buf) do
    {content, _cursor} = Buffer.content_and_cursor(buf)
    content
  end
end
