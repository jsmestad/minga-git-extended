defmodule MingaGitExtended.DiffActions do
  @moduledoc "Owns the Git snapshots and actions behind editor-managed diff views."

  @behaviour MingaEditor.Extension.RepositoryJob.Handler

  alias Minga.Buffer
  alias Minga.Git
  alias Minga.Git.TrackedFile
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.GitDiff
  alias MingaEditor.Extension.GitDiff.Hunk
  alias MingaEditor.Extension.GitDiff.Origin
  alias MingaEditor.Extension.GitDiff.Target
  alias MingaEditor.Extension.RepositoryJob
  alias MingaEditor.Extension.RepositoryJob.Handler

  @typep state :: EditorAPI.state()
  @typep hunk_action :: :stage | :revert | :preview
  @typep direction :: :next | :previous
  @typep status_target :: {String.t(), String.t(), atom(), boolean()}
  @type command ::
          :git_diff_file
          | :git_diff_toggle_staged
          | :git_diff_toggle_layout
          | :next_git_hunk
          | :prev_git_hunk
          | :git_stage_hunk
          | :git_stage_file
          | :git_unstage_file
          | :git_revert_hunk
          | :git_preview_hunk
          | :git_blame_line

  @spec execute(state(), command()) :: state()
  def execute(state, :git_diff_file) do
    with_tracked(state, EditorAPI.active_buffer(state), fn buffer, file ->
      origin = %Origin{
        git_root: file.root,
        rel_path: file.path,
        source_buffer: buffer,
        staged: false
      }

      case Git.index_blob(file.root, file.path) do
        {:ok, indexed} -> open(state, origin, {indexed, file.content})
        {:error, reason} -> EditorAPI.notice(state, "Could not open diff: #{reason}")
      end
    end)
  end

  def execute(state, :git_diff_toggle_staged) do
    buffer = EditorAPI.active_buffer(state)

    case GitDiff.target(state, buffer) do
      {:ok, %Target{origin: %Origin{source_buffer: nil}}} ->
        EditorAPI.notice(state, "Cannot toggle staged: diff opened from status panel")

      {:ok, %Target{origin: origin}} ->
        updated = %{origin | staged: not origin.staged}
        replace(state, buffer, updated, diff_message(updated))

      {:error, {:stale_source, %Target{origin: origin}}} ->
        refresh_stale(state, buffer, origin)

      nil ->
        EditorAPI.notice(state, "Not a diff view")
    end
  end

  def execute(state, :git_diff_toggle_layout) do
    buffer = EditorAPI.active_buffer(state)

    case GitDiff.target(state, buffer) do
      {:ok, %Target{layout: layout}} -> toggle_layout(state, buffer, layout)
      {:error, {:stale_source, %Target{origin: origin}}} -> refresh_stale(state, buffer, origin)
      nil -> EditorAPI.notice(state, "Not a diff view")
    end
  end

  def execute(state, :next_git_hunk), do: navigate(state, :next)
  def execute(state, :prev_git_hunk), do: navigate(state, :previous)
  def execute(state, :git_stage_hunk), do: hunk_action(state, :stage)
  def execute(state, :git_revert_hunk), do: hunk_action(state, :revert)
  def execute(state, :git_preview_hunk), do: hunk_action(state, :preview)
  def execute(state, :git_stage_file), do: stage_file(state, :stage)
  def execute(state, :git_unstage_file), do: stage_file(state, :unstage)

  def execute(state, :git_blame_line) do
    with_tracked(state, EditorAPI.active_buffer(state), fn _buffer, file ->
      {line, _col} = file.cursor

      case Git.blame_line(file.root, file.path, line) do
        {:ok, blame} -> EditorAPI.notice(state, blame)
        :error -> EditorAPI.notice(state, "Blame unavailable")
      end
    end)
  end

  @doc "Proposes reading the exact status entry outside the editor process."
  @spec propose_status(state(), String.t(), status_target()) ::
          state() | {:schedule, state(), RepositoryJob.t()}
  def propose_status(state, root, target) do
    case RepositoryJob.propose(state, :diff_open, root, __MODULE__, target) do
      {:ok, job} -> {:schedule, state, job}
      {:error, reason} -> EditorAPI.notice(state, "Git diff not scheduled: #{inspect(reason)}")
    end
  end

  @impl true
  @spec run(String.t(), status_target()) :: {:ok, Target.contents()} | {:error, String.t()}
  def run(root, {path, _absolute_path, _status, true}) do
    with {:ok, indexed} <- Git.index_blob(root, path) do
      {:ok, {head_content(root, path), indexed}}
    end
  end

  def run(root, {path, absolute_path, _status, false}) do
    with {:ok, indexed} <- Git.index_blob(root, path),
         {:ok, current} <- read_worktree(absolute_path) do
      {:ok, {indexed, current}}
    else
      {:error, reason} when is_atom(reason) -> {:error, "Could not read file: #{inspect(reason)}"}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  @spec on_result(state(), String.t(), Handler.outcome(), status_target()) :: state()
  def on_result(state, root, {:completed, {base, current}}, {path, _absolute, _status, staged}) do
    open(state, %Origin{git_root: root, rel_path: path, staged: staged}, {base, current})
  end

  def on_result(state, _root, {status, error}, _target) do
    message = if is_binary(error), do: error, else: inspect(error)
    EditorAPI.notice(state, "Git diff #{status}: #{message}")
  end

  @spec open(state(), Origin.t(), Target.contents()) :: state()
  defp open(state, origin, contents) do
    case GitDiff.open(state, origin, contents) do
      {:ok, updated} ->
        EditorAPI.notice(updated, diff_message(origin))

      {:error, :stale_source} ->
        EditorAPI.notice(state, "Source buffer changed; retry opening diff")

      {:error, reason} ->
        EditorAPI.notice(state, "Failed to open diff: #{inspect(reason)}")
    end
  end

  @spec diff_message(Origin.t()) :: String.t()
  defp diff_message(%Origin{rel_path: path, staged: staged}) do
    section = if staged, do: "staged", else: "unstaged"
    "Diff (#{section}): #{Path.basename(path)}"
  end

  @spec toggle_layout(state(), pid(), Target.layout()) :: state()
  defp toggle_layout(state, buffer, current) do
    {layout, label} =
      case current do
        :unified -> {:side_by_side, "side-by-side"}
        :side_by_side -> {:unified, "unified"}
      end

    case GitDiff.set_layout(state, buffer, layout) do
      {:ok, updated} ->
        EditorAPI.notice(updated, "Diff layout: #{label}")

      {:error, :unsupported_layout} ->
        EditorAPI.notice(state, "Side-by-side diff is only available in GUI")

      {:error, reason} ->
        EditorAPI.notice(state, "Failed to change diff layout: #{inspect(reason)}")
    end
  end

  @spec navigate(state(), direction()) :: state()
  defp navigate(state, direction) do
    buffer = EditorAPI.active_buffer(state)

    case GitDiff.target(state, buffer) do
      {:ok, _target} ->
        case GitDiff.navigate(state, buffer, direction) do
          {:ok, updated} ->
            updated

          {:error, :no_hunk} ->
            EditorAPI.notice(state, "No #{direction} hunk")

          {:error, reason} ->
            EditorAPI.notice(state, "Hunk navigation failed: #{inspect(reason)}")
        end

      {:error, {:stale_source, %Target{origin: origin}}} ->
        refresh_stale(state, buffer, origin)

      nil ->
        with_tracked(state, buffer, fn source, file ->
          {line, _col} = file.cursor

          case Git.neighbor_change_line(file.hunks, line, direction) do
            nil ->
              EditorAPI.notice(state, "No #{direction} hunk")

            destination ->
              Buffer.move_to(source, {destination, 0})
              state
          end
        end)
    end
  end

  @spec hunk_action(state(), hunk_action()) :: state()
  defp hunk_action(state, action) do
    buffer = EditorAPI.active_buffer(state)

    case GitDiff.target(state, buffer) do
      {:ok, target} -> view_action(state, buffer, action, target)
      {:error, {:stale_source, %Target{origin: origin}}} -> refresh_stale(state, buffer, origin)
      nil -> source_action(state, buffer, action)
    end
  end

  @spec source_action(state(), pid() | nil, hunk_action()) :: state()
  defp source_action(state, buffer, action) do
    with_tracked(state, buffer, fn source, file ->
      {line, _col} = file.cursor

      case Git.change_at(file.hunks, line) do
        nil -> EditorAPI.notice(state, "No hunk at cursor")
        change -> apply_source_action(state, source, action, file, change)
      end
    end)
  end

  @spec apply_source_action(state(), pid(), hunk_action(), TrackedFile.t(), Hunk.change()) ::
          state()
  defp apply_source_action(state, _buffer, :stage, file, change) do
    case stage_change(file.root, file.path, {file.base, file.content}, change) do
      :ok -> EditorAPI.notice(state, "Hunk staged")
      {:error, reason} -> EditorAPI.notice(state, "Stage failed: #{reason}")
    end
  end

  defp apply_source_action(state, buffer, :revert, file, change) do
    with {:ok, _indexed} <- Git.index_blob(file.root, file.path),
         reverted = Git.revert_change(file.content, change),
         {:ok, _version} <- Buffer.replace_content_if_version(buffer, file.version, reverted) do
      EditorAPI.notice(state, "Hunk reverted")
    else
      {:error, :stale} -> EditorAPI.notice(state, "Source buffer changed; retry hunk action")
      {:error, reason} -> EditorAPI.notice(state, "Revert failed: #{inspect(reason)}")
    end
  end

  defp apply_source_action(state, _buffer, :preview, _file, change), do: preview(state, change)

  @spec view_action(state(), pid(), hunk_action(), Target.t()) :: state()
  defp view_action(state, _buffer, action, %Target{origin: %Origin{staged: true}})
       when action in [:stage, :revert],
       do: EditorAPI.notice(state, "Cannot #{action} from a staged diff view")

  defp view_action(state, _buffer, :revert, %Target{origin: %Origin{source_buffer: nil}}),
    do: EditorAPI.notice(state, "Cannot revert: diff opened from status panel")

  defp view_action(state, _buffer, _action, %Target{hunk: nil}),
    do: EditorAPI.notice(state, "No hunk at cursor")

  defp view_action(state, _buffer, :preview, %Target{hunk: %Hunk{change: change}}),
    do: preview(state, change)

  defp view_action(state, buffer, :stage, %Target{origin: origin, contents: contents, hunk: hunk}) do
    {_base, revised} = contents

    with :ok <- check_worktree(origin, revised),
         :ok <- stage_change(origin.git_root, origin.rel_path, contents, hunk.change) do
      replace(state, buffer, origin, "Hunk #{hunk.index}/#{hunk.total} staged")
    else
      :stale -> refresh_stale(state, buffer, origin)
      {:error, reason} -> EditorAPI.notice(state, "Stage failed: #{reason}")
    end
  end

  defp view_action(state, buffer, :revert, %Target{} = target) do
    %Target{origin: origin, contents: {base, revised}, hunk: hunk, source_version: version} =
      target

    # Reverting this projection restores index content, so reject an out-of-date base.
    with {:ok, ^base} <- Git.index_blob(origin.git_root, origin.rel_path),
         reverted = Git.revert_change(revised, hunk.change),
         {:ok, _new_version} <-
           Buffer.replace_content_if_version(origin.source_buffer, version, reverted) do
      replace(state, buffer, origin, "Hunk #{hunk.index}/#{hunk.total} reverted")
    else
      {:ok, _changed} -> refresh_stale(state, buffer, origin)
      {:error, :stale} -> refresh_stale(state, buffer, origin)
      {:error, reason} -> EditorAPI.notice(state, "Revert failed: #{inspect(reason)}")
    end
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      EditorAPI.notice(state, "Source buffer no longer available")
  end

  @spec check_worktree(Origin.t(), binary() | nil) :: :ok | :stale | {:error, String.t()}
  defp check_worktree(%Origin{source_buffer: nil} = origin, revised) do
    case working_content(origin) do
      {:ok, ^revised} -> :ok
      {:ok, _changed} -> :stale
      {:error, reason} -> {:error, "could not read worktree file: #{inspect(reason)}"}
    end
  end

  defp check_worktree(%Origin{}, _revised), do: :ok

  @spec stage_change(String.t(), String.t(), Target.contents(), Hunk.change()) ::
          :ok | {:error, String.t()}
  defp stage_change(root, path, {base, revised}, change) do
    with :ok <- Git.stage_change(root, path, base, revised, change) do
      Git.refresh_status(root)
    end
  end

  @spec stage_file(state(), :stage | :unstage) :: state()
  defp stage_file(state, action) do
    with_tracked(state, EditorAPI.active_buffer(state), fn _buffer, file ->
      {result, label} =
        case action do
          :stage -> {Git.stage(file.root, file.path), "Stage"}
          :unstage -> {Git.unstage(file.root, file.path), "Unstage"}
        end

      case result do
        :ok ->
          Git.refresh_status(file.root)
          EditorAPI.notice(state, "#{label}d: #{file.path}")

        {:error, reason} ->
          EditorAPI.notice(state, "#{label} failed: #{reason}")
      end
    end)
  end

  @spec preview(state(), Hunk.change()) :: state()
  defp preview(state, %{type: :added, count: count}),
    do: EditorAPI.notice(state, "+#{count} added line(s)")

  defp preview(state, %{type: type, old_lines: old_lines, old_count: old_count, count: count}) do
    excerpt = old_lines |> Enum.take(3) |> Enum.join(" | ")
    suffix = if old_count > 3, do: " ...", else: ""

    description =
      case type do
        :deleted -> "-#{old_count} deleted"
        :modified -> "~#{count} modified (was #{old_count} lines)"
      end

    EditorAPI.notice(state, "#{description}: #{excerpt}#{suffix}")
  end

  @spec refresh_stale(state(), pid(), Origin.t()) :: state()
  defp refresh_stale(state, buffer, origin),
    do: replace(state, buffer, origin, "Diff view changed; retry hunk action")

  @spec replace(state(), pid(), Origin.t(), String.t()) :: state()
  defp replace(state, buffer, origin, notice) do
    with {:ok, contents} <- current_contents(origin),
         {:ok, updated} <- GitDiff.replace(state, buffer, origin.staged, contents) do
      EditorAPI.notice(updated, notice)
    else
      {:error, reason} ->
        EditorAPI.notice(state, "#{notice}; diff refresh failed: #{inspect(reason)}")
    end
  end

  @spec current_contents(Origin.t()) :: {:ok, Target.contents()} | {:error, term()}
  defp current_contents(%Origin{git_root: root, rel_path: path, staged: true}) do
    with {:ok, indexed} <- Git.index_blob(root, path) do
      {:ok, {head_content(root, path), indexed}}
    end
  end

  defp current_contents(%Origin{git_root: root, rel_path: path} = origin) do
    with {:ok, indexed} <- Git.index_blob(root, path),
         {:ok, working} <- working_content(origin) do
      {:ok, {indexed, working}}
    end
  end

  @spec working_content(Origin.t()) :: {:ok, binary() | nil} | {:error, term()}
  defp working_content(%Origin{source_buffer: nil, git_root: root, rel_path: path}),
    do: read_worktree(Path.join(root, path))

  defp working_content(%Origin{source_buffer: buffer}) do
    {:ok, Buffer.content(buffer)}
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :closed_source}
  end

  @spec head_content(String.t(), String.t()) :: binary() | nil
  defp head_content(root, path) do
    case Git.show_head(root, path) do
      {:ok, content} -> content
      :error -> nil
    end
  end

  @spec read_worktree(String.t()) ::
          {:ok, binary() | nil} | {:error, File.posix() | :not_regular_file}
  defp read_worktree(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> File.read(path)
      {:ok, _stat} -> {:error, :not_regular_file}
      {:error, :enoent} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @spec with_tracked(state(), pid() | nil, (pid(), TrackedFile.t() -> state())) :: state()
  defp with_tracked(state, nil, _action), do: state

  defp with_tracked(state, buffer, action) do
    case Git.tracked_file(buffer) do
      {:ok, file} -> action.(buffer, file)
      :not_tracked -> EditorAPI.notice(state, "Not in a git repository")
    end
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      EditorAPI.notice(state, "Source buffer no longer available")
  end
end
