ExUnit.start(max_cases: 1)

defmodule MingaGitExtended.TestClipboard do
  @behaviour Minga.Clipboard.Behaviour

  @impl true
  def read, do: nil

  @impl true
  def write(_text), do: :ok
end

profile =
  Path.join(
    System.tmp_dir!(),
    "minga-git-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  )

File.mkdir!(profile)

for {variable, directory} <- [
      {"XDG_CONFIG_HOME", "config"},
      {"XDG_DATA_HOME", "data"},
      {"XDG_CACHE_HOME", "cache"},
      {"XDG_STATE_HOME", "state"}
    ] do
  path = Path.join(profile, directory)
  File.mkdir!(path)
  System.put_env(variable, path)
end

File.mkdir_p!(Path.join(profile, "config/minga"))
ExUnit.after_suite(fn _ -> File.rm_rf!(profile) end)
Logger.configure(level: :warning)
Application.put_env(:minga, :clipboard_module, MingaGitExtended.TestClipboard)
Application.put_env(:minga, :load_extensions, false)
Application.put_env(:minga, :start_editor, false)
Application.put_env(:minga, :git_module, Minga.Git.Stub)
Application.put_env(:minga, :infer_startup_project_root, false)
Application.put_env(:minga, :seal_extension_artifact_generation, false)

parent_test_support = Path.expand("test/support", System.fetch_env!("MINGA_HOST_SOURCE"))

unless Code.ensure_loaded?(Minga.Git.Stub),
  do: Code.require_file(Path.join(parent_test_support, "git_stub.ex"))

Minga.Git.Stub.ensure_table()

unless Code.ensure_loaded?(Minga.Test.GUIWindowDecoder),
  do: Code.require_file(Path.join(parent_test_support, "gui_window_decoder.ex"))

unless Code.ensure_loaded?(Minga.Test.HeadlessPort),
  do: Code.require_file(Path.join(parent_test_support, "headless_port.ex"))

unless Code.ensure_loaded?(MingaEditor.RenderPipeline.TestHelpers),
  do: Code.require_file(Path.join(parent_test_support, "render_pipeline_test_helpers.ex"))

unless Code.ensure_loaded?(Minga.Test.EditorCase),
  do: Code.require_file(Path.join(parent_test_support, "editor_case.ex"))

{:ok, _apps} = Application.ensure_all_started(:minga)
{:ok, _apps} = Application.ensure_all_started(:minga_git_extended)
