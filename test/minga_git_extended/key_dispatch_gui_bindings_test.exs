defmodule MingaGitExtended.KeyDispatchGUIBindingsTest do
  @moduledoc "Tests GUI-only key dispatch bindings."
  # Installs the two diff commands in the editor's command registry.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Command.Registry
  alias Minga.Keymap.Active
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.KeyDispatch
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaGitExtended.Commands

  setup do
    :ok = Registry.register(Registry, :git_diff_file, "View diff", &Commands.git_diff_file/1)

    :ok =
      Registry.register(
        Registry,
        :git_diff_toggle_layout,
        "Toggle diff layout",
        &Commands.git_diff_toggle_layout/1
      )

    :ok =
      Registry.register(
        Registry,
        :git_diff_test_override,
        "Override",
        &EditorAPI.notice(&1, "User diff")
      )

    on_exit(fn ->
      for command <- [:git_diff_file, :git_diff_toggle_layout, :git_diff_test_override] do
        :ok = Registry.unregister(Registry, command)
      end
    end)
  end

  test "SPC g d s is available for GUI frontends only" do
    gui_state = state_with_frontend(:native_gui)
    tui_state = state_with_frontend(:tui)

    assert "Not a diff view" =
             dispatch_keys(gui_state, [32, ?g, ?d, ?s])
             |> MingaEditor.Shell.Traditional.NoticeWorkflow.message()

    assert "Not in a git repository" =
             dispatch_keys(tui_state, [32, ?g, ?d, ?s])
             |> MingaEditor.Shell.Traditional.NoticeWorkflow.message()
  end

  test "TUI keeps SPC g d as the direct diff command" do
    state = state_with_frontend(:tui)

    assert "Not in a git repository" =
             dispatch_keys(state, [32, ?g, ?d])
             |> MingaEditor.Shell.Traditional.NoticeWorkflow.message()
  end

  test "GUI moves the default diff command to SPC g d f" do
    state = state_with_frontend(:native_gui)

    assert nil ==
             dispatch_keys(state, [32, ?g, ?d])
             |> MingaEditor.Shell.Traditional.NoticeWorkflow.message()

    assert "Not in a git repository" =
             dispatch_keys(state, [32, ?g, ?d, ?f])
             |> MingaEditor.Shell.Traditional.NoticeWorkflow.message()
  end

  test "an existing exact user binding for SPC g d s is preserved" do
    keymap_server = start_keymap()
    :ok = Active.bind(keymap_server, :normal, "SPC g d s", :git_diff_test_override, "User diff")

    state = state_with_frontend(:native_gui, keymap_server)
    state = dispatch_keys(state, [32, ?g, ?d, ?s])

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(state) == "User diff"
  end

  test "an existing exact user binding for SPC g d is preserved in GUI" do
    keymap_server = start_keymap()
    :ok = Active.bind(keymap_server, :normal, "SPC g d", :git_diff_test_override, "User diff")

    state = state_with_frontend(:native_gui, keymap_server)
    state = dispatch_keys(state, [32, ?g, ?d])

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(state) == "User diff"
  end

  defp state_with_frontend(frontend_type, keymap_server \\ nil) do
    buf =
      start_supervised!(
        Supervisor.child_spec({Buffer, content: "x"}, id: {:buffer, frontend_type})
      )

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{
        port_manager: self(),
        capabilities: %Capabilities{frontend_type: frontend_type}
      },
      workspace: %SessionState{}
    }

    keymap_server = keymap_server || start_keymap()
    state = %{state | interaction: %{state.interaction | keymap_server: keymap_server}}

    MingaEditor.Handlers.BufferRegistry.add_buffer(state, buf)
  end

  defp start_keymap do
    keymap = start_supervised!(Supervisor.child_spec({Active, name: nil}, id: make_ref()))
    :ok = Active.bind(keymap, :normal, "SPC g d", :git_diff_file, "View diff")
    keymap
  end

  defp dispatch_keys(state, keys) do
    Enum.reduce(keys, state, fn key, acc ->
      KeyDispatch.handle_key(acc, key, 0)
    end)
  end
end
