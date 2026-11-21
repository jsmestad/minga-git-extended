defmodule MingaGitExtended.CommandsBranchDeleteTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.CallbackInvoker
  alias Minga.Extension.CodeLease
  alias Minga.Git.BranchInfo
  alias Minga.Git.Stub
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Input.Prompt
  alias MingaEditor.MinibufferData
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaGitExtended.UI.Picker.GitBranchSource
  alias MingaGitExtended.UI.Prompt.BranchDelete

  @source {:extension, :git_extended_branch_prompt_test}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    :ok = CodeLease.activate_source(@source, [BranchDelete, GitBranchSource])

    :ok =
      Stub.set_branches(root, [
        %BranchInfo{name: "main", current: true},
        %BranchInfo{name: "feature", current: false}
      ])

    task_supervisor = start_supervised!(Task.Supervisor)
    scheduler = start_supervised!({EffectScheduler, task_supervisor: task_supervisor})
    :ok = EffectScheduler.attach(scheduler, self())

    on_exit(fn ->
      Stub.clear(root)
      {:ok, token} = CodeLease.quiesce_source(@source)
      :ok = CodeLease.complete_unload(token)
    end)

    state = TestHelpers.base_state(effect_scheduler: scheduler, rendering: :disabled)
    %{root: root, scheduler: scheduler, state: state}
  end

  test "confirmation deletes the captured branch and reopens its repository picker", ctx do
    opened = open(ctx.state, ctx.root)
    assert MinibufferData.from_state(opened).prompt == "Delete branch feature?"
    {:handled, confirmed} = Prompt.handle_key(opened, ?y, 0)
    assert NoticeWorkflow.message(confirmed) == "Deleted branch feature"
    assert {:ok, [%BranchInfo{name: "main"}]} = Stub.branch_list(ctx.root)
    assert picker_labels(confirmed, ctx.scheduler) == ["main"]
  end

  test "an unmerged branch needs a second explicit confirmation and cancellation does not delete it",
       ctx do
    Stub.set_branch_delete_result(ctx.root, "feature", false, {:error, "not fully merged"})
    {:handled, force} = ctx.state |> open(ctx.root) |> Prompt.handle_key(?y, 0)

    assert MinibufferData.from_state(force).prompt ==
             "Branch feature is not fully merged. Force delete?"

    {:handled, canceled} = Prompt.handle_key(force, ?n, 0)
    assert NoticeWorkflow.message(canceled) == "Branch delete cancelled"
    assert "feature" in picker_labels(canceled, ctx.scheduler)
  end

  test "a failed force delete reports the failure and keeps the branch", ctx do
    Stub.set_branch_delete_result(ctx.root, "feature", false, {:error, "not fully merged"})
    Stub.set_branch_delete_result(ctx.root, "feature", true, {:error, "branch locked"})
    {:handled, force} = ctx.state |> open(ctx.root) |> Prompt.handle_key(?y, 0)
    {:handled, failed} = Prompt.handle_key(force, ?y, 0)
    assert NoticeWorkflow.message(failed) == "Force delete failed: branch locked"
    assert {:ok, branches} = Stub.branch_list(ctx.root)
    assert Enum.any?(branches, &(&1.name == "feature"))
  end

  defp open(state, root) do
    {:ok, opened} =
      CallbackInvoker.invoke(@source, BranchDelete, :open, [state, root, "feature"], :test)

    opened
  end

  defp picker_labels(state, scheduler) do
    assert_receive {:effect_result, ^scheduler, %Outcome{} = outcome}, 2_000
    {:noreply, state} = MingaEditor.handle_info({:effect_result, scheduler, outcome}, state)
    {:picker, %{picker_ui: %{picker: picker}}} = state.shell_runtime.state.modal
    Enum.map(picker.items, & &1.label)
  end
end
