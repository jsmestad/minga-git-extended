defmodule MingaGitExtended.CommandsConflictTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.NormalPrefixes
  alias MingaGitExtended.Commands, as: GitCommands
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    GitStub.ensure_table()
    GitStub.set_root(dir, dir)
    on_exit(fn -> GitStub.clear(dir) end)
    %{root: dir}
  end

  test "]x and [x normal prefixes resolve to merge conflict navigation" do
    trie = NormalPrefixes.trie()

    assert {:prefix, right_bracket} = Bindings.lookup(trie, {?], 0})
    assert {:command, :next_merge_conflict} = Bindings.lookup(right_bracket, {?x, 0})

    assert {:prefix, left_bracket} = Bindings.lookup(trie, {?[, 0})
    assert {:command, :prev_merge_conflict} = Bindings.lookup(left_bracket, {?x, 0})
  end

  test "navigation moves between conflict starts" do
    buffer = start_buffer("before\n" <> conflict("A", "B") <> "\nbetween\n" <> conflict("C", "D"))
    state = state_with_buffer(buffer)

    BufferProcess.move_to(buffer, {0, 0})
    GitCommands.execute(state, :next_merge_conflict)
    assert BufferProcess.cursor(buffer) == {1, 0}

    GitCommands.execute(state, :next_merge_conflict)
    assert BufferProcess.cursor(buffer) == {7, 0}

    GitCommands.execute(state, :prev_merge_conflict)
    assert BufferProcess.cursor(buffer) == {1, 0}
  end

  test "accept current at cursor replaces the conflict block" do
    buffer = start_buffer("before\n" <> conflict("ours", "theirs") <> "\nafter")
    state = state_with_buffer(buffer)

    BufferProcess.move_to(buffer, {2, 0})
    state = GitCommands.execute(state, :git_accept_current_conflict)

    assert BufferProcess.content(buffer) == "before\nours\nafter"
    assert state.shell_runtime.state.notice.message == "Resolved all merge conflicts"
  end

  test "a presented conflict can only change the buffer that offered it" do
    buffer = start_buffer(conflict("ours", "theirs"))
    active = start_buffer(conflict("active", "other"))
    state = state_with_buffer(active)

    accept_presented(state, buffer, BufferProcess.version(buffer), :incoming)

    assert BufferProcess.content(buffer) == "theirs"
    assert BufferProcess.content(active) == conflict("active", "other")
  end

  test "resolving one of multiple conflicts does not save or stage early", %{root: root} do
    path = Path.join(root, "conflict.txt")
    content = two_conflict_content()
    File.write!(path, content)

    buffer = start_supervised!({BufferProcess, [file_path: path]})
    state = state_with_buffer(buffer)

    state = accept_presented(state, buffer, BufferProcess.version(buffer), :current)

    assert BufferProcess.content(buffer) == "ours\nbetween\n" <> conflict("left", "right")
    assert File.read!(path) == content
    assert GitStub.staged_paths(root) == []
    refute_receive {:minga_event, :buffer_saved, _}
    assert state.shell_runtime.state.notice.message == "Resolved merge conflict"
  end

  test "a delayed conflict action rejects a different conflict at the same coordinates" do
    buffer = start_buffer(conflict("ours", "theirs"))
    version = BufferProcess.version(buffer)
    content = conflict("updated", "different")
    :ok = BufferProcess.replace_content(buffer, content)
    state = state_with_buffer(buffer)

    state = accept_presented(state, buffer, version, :incoming)

    assert BufferProcess.content(buffer) == content
    assert state.shell_runtime.state.notice.message == "Merge conflict action is stale"
  end

  test "resolving the final file-backed conflict saves, stages, and publishes buffer_saved", %{
    root: root
  } do
    path = Path.join(root, "conflict.txt")
    File.write!(path, conflict("ours", "theirs"))
    buffer = start_supervised!({BufferProcess, [file_path: path]})
    state = state_with_buffer(buffer)

    Events.subscribe(:buffer_saved)
    on_exit(fn -> Events.unsubscribe(:buffer_saved) end)

    state = GitCommands.execute(state, :git_accept_both_conflict)

    assert_receive {:minga_event, :buffer_saved,
                    %Minga.Events.BufferEvent{buffer: ^buffer, path: ^path}}

    assert File.read!(path) == "ours\ntheirs"
    assert GitStub.staged_paths(root) == ["conflict.txt"]

    assert state.shell_runtime.state.notice.message ==
             "Resolved all merge conflicts and staged conflict.txt"
  end

  defp accept_presented(state, buffer, version, choice) do
    region = %{start_line: 0, end_line: 4}
    event = {:editor_action, :git_accept_conflict, {buffer, version, region, choice}}
    assert {:handled, updated} = GitCommands.handle_editor_event(state, event)
    updated
  end

  defp start_buffer(content) do
    start_supervised!(Supervisor.child_spec({BufferProcess, content: content}, id: make_ref()))
  end

  defp state_with_buffer(buffer) do
    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %SessionState{
        buffers: %Buffers{list: [buffer], active_index: 0, active: buffer},
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => Window.new(1, buffer, 24, 80)},
          active: 1,
          next_id: 2
        }
      }
    }
  end

  defp conflict(current, incoming) do
    "<<<<<<< HEAD\n#{current}\n=======\n#{incoming}\n>>>>>>> branch"
  end

  defp two_conflict_content do
    conflict("ours", "theirs") <> "\nbetween\n" <> conflict("left", "right")
  end
end
