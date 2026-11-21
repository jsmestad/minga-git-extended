defmodule MingaGitExtended.Conflicts do
  @moduledoc "Navigates merge conflicts and stages an exact final resolution after saving it."

  alias Minga.Buffer
  alias Minga.Buffer.Conflict
  alias Minga.Git
  alias MingaEditor.Extension.EditorAPI

  @spec navigate(EditorAPI.state(), :next | :prev) :: EditorAPI.state()
  def navigate(state, direction) do
    case EditorAPI.active_buffer(state) do
      nil ->
        state

      buffer ->
        %{cursor: {line, _col}, entries: entries} = Buffer.conflict_view(buffer)

        case target(entries, line, direction) do
          nil ->
            EditorAPI.notice(state, "No merge conflicts")

          %{start_line: start} ->
            Buffer.move_to(buffer, {start, 0})
            state
        end
    end
  end

  @spec accept_at_cursor(EditorAPI.state(), Conflict.choice()) :: EditorAPI.state()
  def accept_at_cursor(state, choice) do
    case EditorAPI.active_buffer(state) do
      nil ->
        state

      buffer ->
        %{version: version, cursor: {line, _col}} = Buffer.conflict_view(buffer)
        resolve(state, buffer, version, {:cursor, line}, choice)
    end
  end

  @spec resolve(EditorAPI.state(), pid(), non_neg_integer(), Conflict.target(), Conflict.choice()) ::
          EditorAPI.state()
  def resolve(state, buffer, version, target, choice) do
    case Buffer.resolve_conflict(buffer, version, target, choice) do
      {:ok, %{version: new_version, remaining: 0}} ->
        save_and_stage(state, buffer, new_version, Buffer.file_path(buffer))

      {:ok, _partial} ->
        EditorAPI.notice(state, "Resolved merge conflict")

      {:error, :stale} ->
        EditorAPI.notice(state, "Merge conflict action is stale")

      {:error, :not_found} ->
        EditorAPI.notice(state, "No merge conflict at the target")

      {:error, reason} ->
        EditorAPI.notice(state, "Resolve conflict failed: #{inspect(reason)}")
    end
  end

  @spec save_and_stage(EditorAPI.state(), pid(), non_neg_integer(), String.t() | nil) ::
          EditorAPI.state()
  defp save_and_stage(state, _buffer, _version, nil),
    do: EditorAPI.notice(state, "Resolved all merge conflicts")

  defp save_and_stage(state, buffer, version, file) do
    with :ok <- Buffer.save_if_version(buffer, version),
         {:ok, root} <- Git.root_for(file),
         path = Git.relative_path(root, file),
         :ok <- Git.stage(root, path) do
      Git.refresh_status(root)
      EditorAPI.notice(state, "Resolved all merge conflicts and staged #{path}")
    else
      :not_git ->
        EditorAPI.notice(state, "Resolved all merge conflicts; not in a git repository")

      {:error, reason} ->
        EditorAPI.notice(state, "Resolved conflicts, but save/stage failed: #{inspect(reason)}")
    end
  end

  @spec target([Conflict.region()], non_neg_integer(), :next | :prev) :: Conflict.region() | nil
  defp target(entries, line, :next), do: Enum.find(entries, &(&1.start_line > line))

  defp target(entries, line, :prev) do
    Enum.reduce_while(entries, nil, fn entry, previous ->
      if entry.start_line < line, do: {:cont, entry}, else: {:halt, previous}
    end)
  end
end
