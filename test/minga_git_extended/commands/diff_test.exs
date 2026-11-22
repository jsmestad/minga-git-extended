defmodule MingaGitExtended.CommandsDiffTest do
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Git
  alias Minga.Git.Stub
  alias Minga.Git.Tracker
  alias Minga.Project.Root
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

  setup %{tmp_dir: tmp_dir} do
    {:ok, root} = Root.canonical_path(tmp_dir)
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
            %Target{origin: %Origin{staged: true}, contents: {@base, nil}, layout: :side_by_side}} =
             GitDiff.target(shown, view)

    blocked = Commands.execute(shown, :git_revert_hunk)
    assert NoticeWorkflow.message(blocked) == "Cannot revert from a staged diff view"
    assert Buffer.content(ctx.source) == @revised
  end

  test "an unmerged index cannot revert a previously displayed working hunk", ctx do
    {state, _view} = open_view(ctx, :unified)
    :ok = Stub.set_index_blob(ctx.root, @path, {:error, "Git index path is unmerged"})

    updated = Commands.execute(state, :git_revert_hunk)

    assert NoticeWorkflow.message(updated) =~ "unmerged"
    assert Buffer.content(ctx.source) == @revised
    assert File.read!(ctx.working_path) == @revised
  end

  test "staging from a new source file accepts an absent index entry", %{root: root} do
    path = "new.txt"
    content = "new file\n"
    working_path = Path.join(root, path)
    File.write!(working_path, content)

    {state, source, _tracker} = open_tracked(working_path, root)
    assert {:ok, nil} = Stub.index_blob(root, path)

    updated = Commands.execute(state, :git_stage_hunk)

    assert NoticeWorkflow.message(updated) == "Hunk staged"
    assert {:ok, ^content} = Stub.index_blob(root, path)
    assert Buffer.content(source) == content
    assert File.read!(working_path) == content
  end

  test "reloading an alias rebinds source staging to the new repository", %{root: parent} do
    old_root = Path.join(parent, "old-repo")
    new_root = Path.join(parent, "new-repo")
    File.mkdir!(old_root)
    File.mkdir!(new_root)

    old_path = Path.join(old_root, @path)
    new_path = Path.join(new_root, @path)
    new_head = "original in the new repo\n"
    new_text = "changed in the new repo\n"
    File.write!(old_path, @revised)
    File.write!(new_path, new_text)
    :ok = Stub.set_head(old_root, @path, @base)
    :ok = Stub.set_head(new_root, @path, new_head)
    :ok = Stub.set_root(new_root, new_root)
    on_exit(fn -> Stub.clear(new_root) end)

    alias_path = Path.join(parent, "alias.txt")
    File.ln_s!(old_path, alias_path)
    {state, source, previous} = open_tracked(alias_path, old_root)
    assert {:ok, %{root: ^old_root, path: @path}} = Git.tracked_file(source)
    ref = Process.monitor(previous)

    File.rm!(alias_path)
    File.ln_s!(new_path, alias_path)
    assert :ok = Buffer.reload(source)
    assert_receive {:DOWN, ^ref, :process, ^previous, _reason}, 5_000

    assert Buffer.file_path(source) == alias_path

    assert {:ok, %{root: ^new_root, path: @path, base: ^new_head, content: ^new_text}} =
             Git.tracked_file(source)

    updated = Commands.execute(state, :git_stage_hunk)
    assert NoticeWorkflow.message(updated) == "Hunk staged"
    assert {:ok, @base} = Stub.index_blob(old_root, @path)
    assert {:ok, ^new_text} = Stub.index_blob(new_root, @path)
  end

  test "a source diff stops staging if the original path becomes a symlink", ctx do
    {state, view} = open_view(ctx, :unified)
    version = Buffer.version(ctx.source)
    replacement = Path.join(ctx.root, "replacement.txt")
    File.write!(replacement, @revised)
    File.rm!(ctx.working_path)
    File.ln_s!(replacement, ctx.working_path)

    assert Buffer.file_path(ctx.source) == ctx.working_path
    assert Buffer.version(ctx.source) == version
    assert {:error, {:stale_source, %Target{hunk: nil}}} = GitDiff.target(state, view)

    updated = Commands.execute(state, :git_stage_hunk)
    assert NoticeWorkflow.message(updated) =~ "stale_source"
    assert {:ok, @base} = Stub.index_blob(ctx.root, @path)
  end

  test "a source diff stops staging if its captured root becomes a symlink", %{root: parent} do
    root = Path.join(parent, "old-root")
    replacement = Path.join(parent, "replacement-root")
    File.mkdir!(root)
    File.mkdir!(replacement)
    working_path = Path.join(root, @path)
    File.write!(working_path, @revised)
    File.write!(Path.join(replacement, @path), @revised)
    :ok = Stub.set_head(root, @path, @base)
    on_exit(fn -> Stub.clear(root) end)

    source = start_supervised!({Buffer, file_path: working_path}, id: :root_replacement_source)
    {state, view} = open_view(%{root: root, source: source}, :unified)
    version = Buffer.version(source)
    File.rename!(root, root <> "-moved")
    File.ln_s!(replacement, root)

    assert Buffer.file_path(source) == working_path
    assert Buffer.version(source) == version
    assert {:error, {:stale_source, %Target{hunk: nil}}} = GitDiff.target(state, view)
    assert NoticeWorkflow.message(Commands.execute(state, :git_stage_hunk)) =~ "stale_source"
    assert {:ok, @base} = Stub.index_blob(root, @path)
  end

  test "recreating a deleted worktree path as an empty file invalidates its selected deletion",
       ctx do
    File.rm!(ctx.working_path)
    origin = %Origin{git_root: ctx.root, rel_path: @path, staged: false}
    {:ok, shown} = GitDiff.open(TestHelpers.gui_state(), origin, {@base, nil})
    view = EditorAPI.active_buffer(shown)
    File.write!(ctx.working_path, "")

    updated = Commands.execute(shown, :git_stage_hunk)

    assert NoticeWorkflow.message(updated) =~ "retry hunk action"
    assert {:ok, @base} = Stub.show_staged(ctx.root, @path)
    assert {:ok, %Target{contents: {@base, ""}}} = GitDiff.target(updated, view)
  end

  test "a dangling symlink invalidates a selected worktree deletion without staging it", ctx do
    File.rm!(ctx.working_path)
    origin = %Origin{git_root: ctx.root, rel_path: @path, staged: false}
    {:ok, shown} = GitDiff.open(TestHelpers.gui_state(), origin, {@base, nil})
    missing_target = Path.join(ctx.root, "missing.txt")
    File.ln_s!(missing_target, ctx.working_path)

    updated = Commands.execute(shown, :git_stage_hunk)

    assert NoticeWorkflow.message(updated) =~ "Stage failed"
    assert {:ok, @base} = Stub.index_blob(ctx.root, @path)
    assert {:ok, ^missing_target} = File.read_link(ctx.working_path)
  end

  defp open_tracked(path, root) do
    :ok = Stub.set_root(root, root)
    on_exit(fn -> Stub.clear(root) end)

    state = EditorAPI.open_file(TestHelpers.gui_state(), path)
    source = EditorAPI.active_buffer(state)
    assert Buffer.file_path(source) == path
    # The open event comes from this process, so it precedes the barrier.
    :sys.get_state(Tracker)
    tracker = Git.tracking_pid(source)
    assert is_pid(tracker)
    on_exit(fn -> GenServer.stop(source) end)
    {state, source, tracker}
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
