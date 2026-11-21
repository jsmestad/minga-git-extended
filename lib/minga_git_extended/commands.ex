defmodule MingaGitExtended.Commands do
  @moduledoc """
  Git commands: status panel, remote operations (push/pull/fetch), diff view,
  branch picker, hunk navigation, stage, revert, preview, and blame.
  """

  @behaviour MingaEditor.Extension.EventHandler

  alias Minga.Git
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.GitStatus
  alias MingaEditor.Extension.Picker
  alias MingaGitExtended.Conflicts
  alias MingaGitExtended.DiffActions
  alias MingaGitExtended.Effects.CommitMessageGeneration
  alias MingaGitExtended.Effects.RemoteOperation
  alias MingaGitExtended.UI.Picker.GitBranchSource
  alias MingaGitExtended.UI.Picker.GitChangedSource
  alias MingaGitExtended.UI.Picker.GitLogFileSource
  alias MingaGitExtended.UI.Picker.GitLogSource
  alias MingaGitExtended.UI.Picker.GitStashSource

  @type state :: EditorAPI.state()
  @type result :: CommitMessageGeneration.command_result()

  @impl MingaEditor.Extension.EventHandler
  @spec handle_editor_event(state(), MingaEditor.Extension.EventHandler.event()) ::
          MingaEditor.Extension.EventHandler.callback_result()
  def handle_editor_event(
        state,
        {:editor_action, :open_git_diff_for_path, {git_root, rel_path, abs_path, status, staged}}
      )
      when is_binary(git_root) and is_binary(rel_path) and is_binary(abs_path) and
             is_atom(status) and is_boolean(staged) do
    case DiffActions.propose_status(state, git_root, {rel_path, abs_path, status, staged}) do
      {:schedule, _updated, _job} = proposal -> proposal
      updated -> {:handled, updated}
    end
  end

  def handle_editor_event(
        state,
        {:editor_action, :git_accept_conflict, {buffer, version, region, choice}}
      )
      when is_pid(buffer) and is_integer(version) and version >= 0 and
             choice in [:current, :incoming, :both] do
    {:handled, Conflicts.resolve(state, buffer, version, {:region, region}, choice)}
  end

  def handle_editor_event(state, {:editor_action, :git_status_remote, {root, operation}})
      when is_binary(root) and operation in [:push, :pull, :fetch] do
    case RemoteOperation.propose(state, root, operation) do
      {:schedule, _updated, _job} = proposal -> proposal
      updated -> {:handled, updated}
    end
  end

  def handle_editor_event(_state, _event), do: :not_matched

  @command_specs [
    {:git_status_toggle, "Git status", false},
    {:git_changed_files, "Changed files", false},
    {:git_log, "Git log", false},
    {:git_log_file, "Git log for current file", true},
    {:git_branch_picker, "Switch branch", false},
    {:git_stash_save, "Stash changes", false},
    {:git_stash_pop, "Pop stash", false},
    {:git_stash_list, "List stashes", false},
    {:git_stash_drop, "Drop stash", false},
    {:git_push, "Push", false},
    {:git_pull, "Pull", false},
    {:git_fetch, "Fetch", false},
    {:git_pull_and_retry, "Pull and retry push", false},
    {:git_diff_file, "View diff", true},
    {:git_diff_toggle_layout, "Toggle side-by-side diff", true},
    {:next_git_hunk, "Next git hunk", true},
    {:prev_git_hunk, "Previous git hunk", true},
    {:next_merge_conflict, "Next merge conflict", true},
    {:prev_merge_conflict, "Previous merge conflict", true},
    {:git_accept_current_conflict, "Accept current conflict side", true},
    {:git_accept_incoming_conflict, "Accept incoming conflict side", true},
    {:git_accept_both_conflict, "Accept both conflict sides", true},
    {:git_stage_hunk, "Stage hunk", true},
    {:git_stage_file, "Stage current file", true},
    {:git_unstage_file, "Unstage current file", true},
    {:git_revert_hunk, "Revert hunk", true},
    {:git_preview_hunk, "Preview hunk", true},
    {:git_blame_line, "Blame line", true},
    {:git_commit_open, "Open commit panel", false},
    {:git_amend_open, "Open amend panel", false},
    {:git_diff_toggle_staged, "Toggle diff staged/unstaged", true},
    {:git_generate_commit_message, "Generate AI commit message", false}
  ]

  @spec execute(state(), atom()) :: result()

  for {command_name, _description, _requires_buffer} <- @command_specs do
    @spec unquote(command_name)(state()) :: result()
    def unquote(command_name)(state), do: execute(state, unquote(command_name))
  end

  # ── Status panel toggle ────────────────────────────────────────────────────

  def execute(state, :git_status_toggle), do: GitStatus.toggle(state)

  # ── Changed files picker ────────────────────────────────────────────────────

  def execute(state, :git_changed_files), do: open_repository_picker(state, GitChangedSource)
  def execute(state, :git_log), do: open_repository_picker(state, GitLogSource)
  def execute(state, :git_branch_picker), do: open_repository_picker(state, GitBranchSource)

  def execute(state, :git_log_file) do
    with path when is_binary(path) <- EditorAPI.active_path(state),
         {:ok, root} <- git_root_for_file(path) do
      Picker.open(state, GitLogFileSource, {root, Git.relative_path(root, path)})
    else
      _not_a_git_file -> EditorAPI.notice(state, "No git tracking for this file")
    end
  end

  def execute(state, :git_stash_save) do
    with_git_root(state, fn git_root ->
      case Git.stash(git_root, include_untracked: true) do
        :ok ->
          Git.refresh_status(git_root)
          EditorAPI.notice(state, "Stashed changes")

        {:error, reason} ->
          stash_save_status(state, reason)
      end
    end)
  end

  def execute(state, :git_stash_pop) do
    with_git_root(state, fn git_root ->
      case Git.stash_pop(git_root) do
        :ok ->
          Git.refresh_status(git_root)
          EditorAPI.notice(state, "Popped stash")

        {:error, reason} ->
          EditorAPI.notice(state, "Stash pop failed: #{reason}")
      end
    end)
  end

  def execute(state, :git_stash_list),
    do: with_git_root(state, &Picker.open(state, GitStashSource, {&1, :list}))

  def execute(state, :git_stash_drop),
    do: with_git_root(state, &Picker.open(state, GitStashSource, {&1, :drop}))

  def execute(state, :git_push), do: propose_remote(state, :push)
  def execute(state, :git_pull), do: propose_remote(state, :pull)
  def execute(state, :git_fetch), do: propose_remote(state, :fetch)
  def execute(state, :git_pull_and_retry), do: propose_remote(state, :pull_and_retry)

  # ── Diff view ──────────────────────────────────────────────────────────────

  def execute(state, command)
      when command in [
             :git_diff_file,
             :git_diff_toggle_staged,
             :git_diff_toggle_layout,
             :next_git_hunk,
             :prev_git_hunk,
             :git_stage_hunk,
             :git_stage_file,
             :git_unstage_file,
             :git_revert_hunk,
             :git_preview_hunk,
             :git_blame_line
           ],
      do: DiffActions.execute(state, command)

  # ── AI commit message ──────────────────────────────────────────────────────

  def execute(state, :git_generate_commit_message) do
    case EditorAPI.git_root(state) do
      {:ok, root} -> CommitMessageGeneration.propose(state, root)
      :not_git -> EditorAPI.notice(state, "Not in a git repository")
    end
  end

  # ── Navigation ─────────────────────────────────────────────────────────────

  def execute(state, :next_merge_conflict), do: Conflicts.navigate(state, :next)
  def execute(state, :prev_merge_conflict), do: Conflicts.navigate(state, :prev)

  def execute(state, :git_accept_current_conflict),
    do: Conflicts.accept_at_cursor(state, :current)

  def execute(state, :git_accept_incoming_conflict),
    do: Conflicts.accept_at_cursor(state, :incoming)

  def execute(state, :git_accept_both_conflict), do: Conflicts.accept_at_cursor(state, :both)

  # ── Commit / amend ────────────────────────────────────────────────────────

  def execute(state, :git_commit_open), do: open_git_commit_prompt(state, :commit)
  def execute(state, :git_amend_open), do: open_git_commit_prompt(state, :amend)

  @spec propose_remote(state(), RemoteOperation.operation()) :: result()
  defp propose_remote(state, operation) do
    case EditorAPI.git_root(state) do
      {:ok, root} -> RemoteOperation.propose(state, root, operation)
      :not_git -> EditorAPI.notice(state, "Not in a git repository")
    end
  end

  @spec git_root_for_file(String.t()) :: {:ok, String.t()} | :not_git | {:error, String.t()}
  defp git_root_for_file(file_path) do
    Git.root_for(file_path)
  end

  @spec stash_save_status(state(), String.t()) :: state()
  defp stash_save_status(state, "No changes to stash"),
    do: EditorAPI.notice(state, "No changes to stash")

  defp stash_save_status(state, "No local changes to save"),
    do: EditorAPI.notice(state, "No changes to stash")

  defp stash_save_status(state, reason),
    do: EditorAPI.notice(state, "Stash failed: #{reason}")

  @spec open_repository_picker(state(), module()) :: state()
  defp open_repository_picker(state, source),
    do: with_git_root(state, &Picker.open(state, source, &1))

  @spec with_git_root(state(), (String.t() -> state())) :: state()
  defp with_git_root(state, fun) do
    case EditorAPI.git_root(state) do
      {:ok, git_root} ->
        fun.(git_root)

      :not_git ->
        EditorAPI.notice(state, "Not in a git repository")
    end
  end

  @spec open_git_commit_prompt(state(), MingaGitExtended.UI.Prompt.GitCommit.variant()) :: state()
  defp open_git_commit_prompt(state, variant) do
    case GitStatus.prepare_commit(state) do
      {state, {:ok, root, last_message}} ->
        default = if variant == :amend, do: last_message || "", else: ""
        MingaGitExtended.UI.Prompt.GitCommit.open(state, root, variant, default)

      {state, :not_git} ->
        EditorAPI.notice(state, "Not in a git repository")
    end
  end
end
