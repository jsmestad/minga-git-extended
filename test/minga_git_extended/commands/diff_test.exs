defmodule MingaGitExtended.CommandsDiffTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Git.Stub
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.GitDiff
  alias MingaEditor.Extension.GitDiff.Origin
  alias MingaEditor.Extension.GitDiff.Target
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaGitExtended.Commands

  @moduletag :tmp_dir
  @path "file.txt"
  @base "old first\ncontext\nold second\n"
  @revised "new first\ncontext\nnew second\n"
  @first_staged "new first\ncontext\nold second\n"

  setup %{tmp_dir: root} do
    file = Path.join(root, @path)
    File.write!(file, @revised)
    :ok = Stub.set_head(root, @path, @base)
    source = start_supervised!({Buffer, file_path: file})
    on_exit(fn -> Stub.clear(root) end)
    %{root: root, working_path: file, source: source}
  end

  test "staging one side-by-side hunk retains the second edit and the layout", ctx do
    {state, view} = open_view(ctx, :side_by_side)
    updated = Commands.execute(state, :git_stage_hunk)

    assert {:ok, @first_staged} = Stub.show_staged(ctx.root, @path)
    assert Buffer.content(ctx.source) == @revised
    assert File.read!(ctx.working_path) == @revised
    assert NoticeWorkflow.message(updated) == "Hunk 1/2 staged"

    assert {:ok, %Target{layout: :side_by_side, contents: {@first_staged, @revised}}} =
             GitDiff.target(updated, view)
  end

  test "reverting a displayed hunk only restores that change and preserves the layout", ctx do
    {state, view} = open_view(ctx, :side_by_side)
    updated = Commands.execute(state, :git_revert_hunk)
    reverted = "old first\ncontext\nnew second\n"

    assert Buffer.content(ctx.source) == reverted
    assert File.read!(ctx.working_path) == @revised
    assert {:ok, @base} = Stub.show_staged(ctx.root, @path)

    assert {:ok, %Target{layout: :side_by_side, contents: {@base, ^reverted}}} =
             GitDiff.target(updated, view)
  end

  test "a context row does not revert the next change", ctx do
    {state, view} = open_view(ctx, :unified)
    :ok = Buffer.move_to(view, {2, 0})
    updated = Commands.execute(state, :git_revert_hunk)

    assert NoticeWorkflow.message(updated) == "No hunk at cursor"
    assert Buffer.content(ctx.source) == @revised
  end

  test "a source edit refreshes a stale diff without staging its old cursor target", ctx do
    {state, view} = open_view(ctx, :unified)
    edited = "a later edit\ncontext\nnew second\n"
    :ok = Buffer.replace_content(ctx.source, edited)
    updated = Commands.execute(state, :git_stage_hunk)

    assert {:ok, @base} = Stub.show_staged(ctx.root, @path)
    assert NoticeWorkflow.message(updated) =~ "retry hunk action"
    assert {:ok, %Target{contents: {@base, ^edited}}} = GitDiff.target(updated, view)
  end

  test "a staged deletion can be inspected without reverting the working buffer", ctx do
    {state, _} = open_view(ctx, :side_by_side)
    :ok = Stub.set_staged(ctx.root, @path, :deleted)
    shown = Commands.execute(state, :git_diff_toggle_staged)
    view = EditorAPI.active_buffer(shown)

    assert {:ok,
            %Target{origin: %Origin{staged: true}, contents: {@base, ""}, layout: :side_by_side}} =
             GitDiff.target(shown, view)

    blocked = Commands.execute(shown, :git_revert_hunk)
    assert NoticeWorkflow.message(blocked) == "Cannot revert from a staged diff view"
    assert Buffer.content(ctx.source) == @revised
  end

  defp open_view(ctx, layout) do
    origin = %Origin{
      git_root: ctx.root,
      rel_path: @path,
      staged: false,
      source_buffer: ctx.source
    }

    {:ok, opened} = GitDiff.open(TestHelpers.gui_state(), origin, {@base, @revised})
    view = EditorAPI.active_buffer(opened)
    {:ok, shown} = GitDiff.set_layout(opened, view, layout)
    {shown, view}
  end
end
