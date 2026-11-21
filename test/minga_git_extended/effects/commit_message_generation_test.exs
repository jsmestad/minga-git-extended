defmodule MingaGitExtended.Effects.CommitMessageGenerationTest do
  # The test Git and generator fixtures use a shared process registration.
  use ExUnit.Case, async: false

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias Minga.Project.FileTree
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.RepositoryJob
  alias MingaEditor.PromptUI
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaGitExtended.Effects.CommitMessageGeneration
  alias MingaGitExtended.Test.EffectDependencies, as: Dependencies
  alias MingaGitExtended.UI.Prompt.GitCommit

  @source {:extension, :minga_git_extended}
  @root "/tmp/repo-a"
  @timeout 2_000

  setup do
    Dependencies.reset(self())
    :ok = CodeLease.activate_source(@source, [CommitMessageGeneration, GitCommit])

    on_exit(fn ->
      {:ok, token} = CodeLease.quiesce_source(@source)
      :ok = CodeLease.complete_unload(token)
    end)

    supervisor = start_supervised!(Task.Supervisor)
    scheduler = start_supervised!({EffectScheduler, task_supervisor: supervisor})
    :ok = EffectScheduler.attach(scheduler, self())

    state = %EditorState{
      effect_scheduler: scheduler,
      frontend: %MingaEditor.State.Frontend{backend: :headless},
      workspace: %SessionState{}
    }

    %{state: project(state, @root), scheduler: scheduler}
  end

  test "reads the captured staged diff in the worker and offers an editable message", %{
    state: state
  } do
    {state, _request} = schedule(state)
    assert state.shell_runtime.state.notice.message == "Generating commit message…"
    assert_receive {:dependency_called, :staged_diff, worker, {@root, [staged: true]}}, @timeout
    assert_receive {:dependency_called, :generator, ^worker, "diff --git"}, @timeout
    refute worker == self()

    {state, outcome} = finish(state)
    assert outcome.value == {:completed, "feat: generated"}
    assert PromptUI.render_data(state) == {"Commit message: ", "feat: generated", 15}
  end

  test "empty or unavailable staged diff never calls generation", %{state: state} do
    for {result, message} <- [
          {{:ok, ""}, "Nothing staged to generate a message for"},
          {{:error, "index unavailable"}, "Failed to read staged diff: index unavailable"}
        ] do
      Dependencies.put(:staged_diff, {:return, result})
      {started, _request} = schedule(state)
      {finished, _outcome} = finish(started)
      assert finished.shell_runtime.state.notice.message == message
      refute_received {:dependency_called, :generator, _, _}
      refute PromptUI.open?(finished)
    end
  end

  test "provider errors and exceptions cannot open a commit prompt", %{state: state} do
    for {action, expected} <- [
          {{:return, {:error, "provider unavailable"}}, "provider unavailable"},
          {{:raise, "generator boom"}, "Commit message generation failed:"},
          {{:exit, :generator_exit}, "Commit message generation failed:"}
        ] do
      Dependencies.put(:generator, action)
      {started, _request} = schedule(state)
      {finished, _outcome} = finish(started)
      assert String.starts_with?(finished.shell_runtime.state.notice.message, expected)
      refute PromptUI.open?(finished)
    end
  end

  test "an outstanding generation cannot overwrite an open prompt", %{state: state} do
    {started, _request} = schedule(state)
    occupied = PromptUI.open(started, MingaEditor.UI.Prompt.WorkspaceRename)
    {finished, _outcome} = finish(occupied)
    assert PromptUI.render_data(finished) == PromptUI.render_data(occupied)

    assert finished.shell_runtime.state.notice.message ==
             "Commit message ready (prompt already open)"
  end

  test "switching projects and returning to the same root does not revive the result", %{
    state: state
  } do
    Dependencies.put(:generator, {:block, {:ok, "late subject"}})
    {started, _request} = schedule(state)
    assert_receive {:dependency_called, :generator, worker, "diff --git"}, @timeout
    switched = started |> project("/tmp/repo-b") |> project(@root)
    send(worker, {:release_dependency, :generator})

    {finished, outcome} = finish(switched)
    assert outcome.value == {:stale, :repository_changed}
    refute PromptUI.open?(finished)
  end

  test "timeout stops the worker without admitting a duplicate", %{
    state: state,
    scheduler: scheduler
  } do
    Dependencies.put(:generator, {:block, {:ok, "late subject"}})
    {started, request} = schedule(state)
    assert_receive {:dependency_called, :generator, worker, "diff --git"}, @timeout
    monitor = Process.monitor(worker)

    duplicate = submit(started)
    assert duplicate.shell_runtime.state.notice.message == "A repository job is already running"
    send(scheduler, {:effect_timeout, request.id})
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, @timeout

    {finished, _outcome} = finish(duplicate)
    assert finished.shell_runtime.state.notice.message == "Commit message generation timed out"
    refute PromptUI.open?(finished)
  end

  defp project(state, root) do
    tree = FileTreeState.begin_root_scan(state.workspace.file_tree, FileTree.new(root), :project)
    %{state | workspace: SessionState.set_file_tree(state.workspace, tree)}
  end

  defp submit(state) do
    assert {:ok, {:schedule, ^state, job}} =
             CallbackInvoker.invoke(
               @source,
               CommitMessageGeneration,
               :propose,
               [state, @root, {Dependencies, Dependencies}],
               :command
             )

    RepositoryJob.submit(state, @source, job)
  end

  defp schedule(state) do
    state = submit(state)

    assert_receive {:effect_lifecycle, %Outcome{value: :running, request: request} = outcome},
                   @timeout

    {started, _outcome} = RepositoryJob.apply(state, outcome)
    {started, request}
  end

  defp finish(state) do
    scheduler = state.effect_scheduler
    assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, @timeout
    assert :ok = EffectScheduler.claim(scheduler, outcome)
    {updated, finished} = RepositoryJob.apply(state, outcome)
    EffectScheduler.finalize(scheduler, finished)
    _ordered = EffectScheduler.stats(scheduler)
    {updated, finished}
  end
end
