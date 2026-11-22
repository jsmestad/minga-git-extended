defmodule MingaGitExtended.CommandsCommitTest do
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Extension.CodeLease
  alias Minga.Git.Stub
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.PromptUI
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaGitExtended.Commands

  @source {:extension, :git_extended_commit_test}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    state = TestHelpers.base_state()
    :ok = Sidebar.register_git_status(Sidebar.table_for(state), @source)
    :ok = CodeLease.activate_source(@source, [Commands])

    on_exit(fn ->
      {:ok, token} = CodeLease.quiesce_source(@source)
      :ok = CodeLease.complete_unload(token)
    end)

    path = Path.join(root, "current.txt")
    File.write!(path, "tracked text\n")
    :ok = Buffer.open(state.workspace.buffers.active, path)
    on_exit(fn -> Stub.clear(path) end)

    %{state: state, path: path}
  end

  test "commit and amend keep the repository-service notice and do not open a prompt", ctx do
    :ok = Stub.set_root(ctx.path, ctx.tmp_dir)

    for command <- [:git_commit_open, :git_amend_open] do
      result = Commands.execute(ctx.state, command)
      assert NoticeWorkflow.message(result) == "Git.Repo not available"
      refute PromptUI.open?(result)
    end
  end

  test "commit and amend identify a file outside any repository", ctx do
    for command <- [:git_commit_open, :git_amend_open] do
      result = Commands.execute(ctx.state, command)
      assert NoticeWorkflow.message(result) == "Not in a git repository"
      refute PromptUI.open?(result)
    end
  end
end
