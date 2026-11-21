defmodule MingaGitExtended.UI.Picker.GitChangedSource do
  @moduledoc "Lists a repository's uncommitted changes with live file previews."
  @behaviour MingaEditor.Extension.Picker.Source

  alias Minga.Git
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Picker.Item
  alias MingaEditor.Extension.Picker.Source

  @typedoc "The absolute repository root."
  @type args :: Path.t()

  @impl true
  @spec title() :: String.t()
  def title, do: "Changed Files"

  @impl true
  @spec candidates(args(), :start) :: {:ok, [Item.t()], :done} | {:error, String.t()}
  def candidates(root, :start) do
    with {:ok, entries} <- Git.status(root, untracked_mode: :all) do
      {:ok, Enum.map(entries, &format_entry/1), :done}
    end
  end

  @impl true
  @spec live_file_preview?() :: boolean()
  def live_file_preview?, do: true

  @impl true
  @spec preview(Item.t(), args()) :: Source.preview()
  def preview(%Item{id: path}, root), do: {:file, Path.join(root, path)}

  @impl true
  @spec on_select(EditorAPI.state(), Item.t(), args()) :: EditorAPI.state()
  def on_select(state, %Item{id: path}, root),
    do: EditorAPI.open_file(state, Path.join(root, path))

  @spec format_entry(Git.status_entry()) :: Item.t()
  defp format_entry(entry) do
    dir = Path.dirname(entry.path)

    %Item{
      id: entry.path,
      label: Path.basename(entry.path),
      description: if(dir == ".", do: "", else: dir),
      annotation: status_annotation(entry.status),
      icon: "\u{E612}",
      icon_color: 0x6D8086,
      two_line: true
    }
  end

  @spec status_annotation(atom()) :: String.t()
  defp status_annotation(:modified), do: "M"
  defp status_annotation(:added), do: "A"
  defp status_annotation(:deleted), do: "D"
  defp status_annotation(:untracked), do: "?"
  defp status_annotation(:renamed), do: "R"
  defp status_annotation(:copied), do: "C"
  defp status_annotation(:conflict), do: "!"
  defp status_annotation(_status), do: ""
end
