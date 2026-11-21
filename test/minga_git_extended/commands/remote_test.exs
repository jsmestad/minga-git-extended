defmodule MingaGitExtended.RemoteTest do
  # The injected Git adapter uses a shared test registry.
  use ExUnit.Case, async: false

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias Minga.Project.FileTree
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Extension.RepositoryJob
  alias MingaEditor.Shell.Traditional.GitToastWorkflow
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaGitExtended.Effects.RemoteOperation
  alias MingaGitExtended.Test.EffectDependencies, as: Dependencies

  @source {:extension, :minga_git_extended}
  @root "/tmp/git-a"
  @timeout 2_000

  setup do
    Dependencies.reset(self())
    :ok = CodeLease.activate_source(@source, [RemoteOperation])

    on_exit(fn ->
      {:ok, token} = CodeLease.quiesce_source(@source)
      :ok = CodeLease.complete_unload(token)
    end)

    supervisor = start_supervised!(Task.Supervisor)
    scheduler = start_supervised!({EffectScheduler, task_supervisor: supervisor})
    :ok = EffectScheduler.attach(scheduler, self())

    state = %EditorState{
      effect_scheduler: scheduler,
      frontend: %MingaEditor.State.Frontend{backend: :headless, rendering: :disabled},
      workspace: %SessionState{}
    }

    %{state: project(state, @root), scheduler: scheduler}
  end

  test "each remote operation targets the captured repository and refreshes it", %{state: state} do
    for {op, message} <- [push: "Pushed", pull: "Pulled", fetch: "Fetched"] do
      {started, _request} = start_operation(state, op)
      assert_receive {:dependency_called, {:remote, ^op}, worker, @root}, @timeout
      refute worker == self()
      assert_receive {:dependency_called, :refresh, ^worker, @root}, @timeout
      {result, outcome} = finish(started)
      assert outcome.value == {:completed, :ok}

      assert %{message: ^message, level: :success, retry: nil} =
               result.shell_runtime.state.git_toast
    end
  end

  test "a non-fast-forward retry runs the original pull then push; old toast clicks are ignored",
       %{
         state: state,
         scheduler: scheduler
       } do
    failed = reject_push(state)
    old_id = failed.shell_runtime.state.git_toast.id
    replacement = reject_push(failed)
    id = replacement.shell_runtime.state.git_toast.id
    Dependencies.put({:remote, :push}, {:return, :ok})

    assert ^replacement = GitToastWorkflow.retry(replacement, old_id)
    refute EffectScheduler.active?(scheduler, RepositoryJob)

    {:noreply, pending} =
      MingaEditor.handle_info(
        {:minga_input, {:gui_action, {:git_pull_and_retry, id}}},
        replacement
      )

    {pending, _request} = receive_start(pending)
    assert_receive {:dependency_called, {:remote, :pull}, worker, @root}, @timeout
    assert_receive {:dependency_called, {:remote, :push}, ^worker, @root}, @timeout
    {finished, outcome} = finish(pending)
    assert outcome.value == {:completed, :ok}
    assert finished.shell_runtime.state.notice.message == "Pushed"
  end

  test "a toast cannot retry after switching to another repository and back", %{
    state: state,
    scheduler: scheduler
  } do
    failed = reject_push(state)
    id = failed.shell_runtime.state.git_toast.id
    switched = failed |> project("/tmp/git-b") |> project(@root)
    rejected = GitToastWorkflow.retry(switched, id)

    assert rejected.shell_runtime.state.notice.message == "Repository job was not scheduled"
    refute EffectScheduler.active?(scheduler, RepositoryJob)
    refute_received {:dependency_called, {:remote, :pull}, _, _}
  end

  test "retry never pushes after a failed pull", %{state: state} do
    Dependencies.put({:remote, :pull}, {:return, {:error, "conflict"}})
    {started, _request} = start_operation(state, :pull_and_retry)
    {finished, outcome} = finish(started)
    assert outcome.value == {:failed, "pull failed: conflict"}

    assert finished.shell_runtime.state.notice.message ==
             "Pull and retry failed: pull failed: conflict"

    refute_received {:dependency_called, {:remote, :push}, _, _}
  end

  test "an exception refreshes the original repo and reports a terminal failure", %{state: state} do
    Dependencies.put({:remote, :fetch}, {:raise, "fetch broke"})
    {started, _request} = start_operation(state, :fetch)
    {finished, outcome} = finish(started)

    assert {:failed, {:callback_failed, @source, RemoteOperation, :run, :exception, _}} =
             outcome.value

    assert_receive {:dependency_called, :refresh, _, @root}, @timeout
    assert finished.shell_runtime.state.notice.message =~ "Fetch failed"
  end

  test "canceling a blocked remote leaves no retry authority", %{
    state: state,
    scheduler: scheduler
  } do
    Dependencies.put({:remote, :pull}, {:block, :ok})
    {started, request} = start_operation(state, :pull)
    assert_receive {:dependency_called, {:remote, :pull}, _, @root}, @timeout
    :ok = EffectScheduler.cancel(scheduler, request.id)
    {finished, outcome} = finish(started)
    assert outcome.value == {:canceled, :requested}

    assert %{message: "Git operation canceled", retry: nil} =
             finished.shell_runtime.state.git_toast
  end

  defp reject_push(state) do
    Dependencies.put({:remote, :push}, {:return, {:error, "fetch first"}})
    {started, _request} = start_operation(state, :push)
    assert_receive {:dependency_called, {:remote, :push}, _, @root}, @timeout
    {failed, outcome} = finish(started)
    assert outcome.value == {:failed, "fetch first"}
    assert %{retry: {@source, _job}} = failed.shell_runtime.state.git_toast
    failed
  end

  defp start_operation(state, operation) do
    assert {:ok, {:schedule, ^state, job}} =
             CallbackInvoker.invoke(
               @source,
               RemoteOperation,
               :propose,
               [state, @root, operation, Dependencies],
               :command
             )

    state |> RepositoryJob.submit(@source, job) |> receive_start()
  end

  defp receive_start(state) do
    assert_receive {:effect_lifecycle, %Outcome{value: :running, request: request} = running},
                   @timeout

    {updated, _outcome} = RepositoryJob.apply(state, running)
    {updated, request}
  end

  defp finish(state) do
    scheduler = state.effect_scheduler
    assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, @timeout
    assert :ok = EffectScheduler.claim(scheduler, outcome)
    {result, terminal} = RepositoryJob.apply(state, outcome)
    EffectScheduler.finalize(scheduler, terminal)
    _ordered = EffectScheduler.stats(scheduler)
    {result, terminal}
  end

  defp project(state, root) do
    tree = FileTreeState.begin_root_scan(state.workspace.file_tree, FileTree.new(root), :project)
    %{state | workspace: SessionState.set_file_tree(state.workspace, tree)}
  end
end
