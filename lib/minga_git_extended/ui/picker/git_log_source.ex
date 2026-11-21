defmodule MingaGitExtended.UI.Picker.GitLogSource do
  @moduledoc "Browses a repository's commit history with on-demand patch previews."
  @behaviour MingaEditor.Extension.Picker.Source

  alias Minga.Git
  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Picker.Item
  alias MingaEditor.Extension.Picker.Source

  @page_size 50
  @preview_limit 200
  @hash_fg 0x61AFEF
  @header_fg 0xC678DD
  @hunk_fg 0x56B6C2
  @added_fg 0x98C379
  @deleted_fg 0xE06C75

  @typedoc "The absolute repository root. The file-log source adds a repository-relative path."
  @type args :: Path.t() | {Path.t(), Path.t()}
  @typep page_result :: {:ok, [Item.t()], Source.next_page()} | {:error, String.t()}

  @impl true
  @spec title() :: String.t()
  def title, do: "Git Log"

  @impl true
  @spec candidates(args(), Source.page_request()) :: page_result()
  def candidates(args, :start) do
    {root, path} = scope(args)

    case Git.log(root, count: 1) do
      {:ok, [head]} -> page(root, path, head.hash, 0)
      {:ok, []} -> {:ok, [], :done}
      {:error, _reason} = error -> error
    end
  end

  def candidates(args, {:continue, {head, skip}}) do
    {root, path} = scope(args)
    page(root, path, head, skip)
  end

  @impl true
  @spec on_select(EditorAPI.state(), Item.t(), args()) :: EditorAPI.state()
  def on_select(state, %Item{id: hash}, _args) do
    EditorAPI.notice(state, "Git commit #{String.slice(hash, 0, 12)}")
  end

  @impl true
  @spec preview(Item.t(), args()) :: Source.preview()
  def preview(%Item{id: hash}, args) do
    {root, path} = scope(args)

    case Git.diff(root, with_path([commit: hash], path)) do
      {:ok, ""} -> {:lines, [[{"No diff for this commit", :default, false}]]}
      {:ok, diff} -> {:lines, diff_preview_lines(diff)}
      {:error, reason} -> {:error, "Failed to load diff: #{reason}"}
    end
  end

  @spec scope(args()) :: {Path.t(), Path.t() | nil}
  defp scope({root, path}), do: {root, path}
  defp scope(root), do: {root, nil}

  @spec page(Path.t(), Path.t() | nil, String.t(), non_neg_integer()) :: page_result()
  defp page(root, path, head, skip) do
    opts = with_path([count: @page_size + 1, revision: head, skip: skip], path)

    with {:ok, entries} <- Git.log(root, opts) do
      {visible, lookahead} = Enum.split(entries, @page_size)
      next = if lookahead == [], do: :done, else: more(head, skip + @page_size)
      {:ok, Enum.map(visible, &format_entry/1), next}
    end
  end

  @spec with_path(keyword(), Path.t() | nil) :: keyword()
  defp with_path(opts, nil), do: opts
  defp with_path(opts, path), do: [{:path, path} | opts]

  @spec format_entry(Git.log_entry()) :: Item.t()
  defp format_entry(entry) do
    %Item{
      id: entry.hash,
      label: entry.message,
      description: "#{entry.author} · #{entry.date}",
      annotation: entry.short_hash,
      search_text: "#{entry.hash} #{entry.short_hash} #{entry.author} #{entry.message}"
    }
  end

  @spec more(String.t(), non_neg_integer()) :: Source.next_page()
  defp more(head, shown) do
    item = %Item{
      id: {:load_more, shown},
      label: "Load more...",
      description: "Show #{shown + @page_size} commits",
      annotation: "+#{@page_size}"
    }

    {:more, {head, shown}, item}
  end

  @spec diff_preview_lines(String.t()) :: Source.styled_lines()
  defp diff_preview_lines(diff) do
    diff
    |> String.splitter("\n")
    |> Enum.take(@preview_limit)
    |> Enum.map(&style_diff_line/1)
  end

  @spec style_diff_line(String.t()) :: [Source.preview_segment()]
  defp style_diff_line("diff --git" <> _ = line), do: [{line, @header_fg, true}]
  defp style_diff_line("@@" <> _ = line), do: [{line, @hunk_fg, true}]
  defp style_diff_line("+++" <> _ = line), do: [{line, @hash_fg, true}]
  defp style_diff_line("---" <> _ = line), do: [{line, @hash_fg, true}]
  defp style_diff_line("+" <> _ = line), do: [{line, @added_fg, false}]
  defp style_diff_line("-" <> _ = line), do: [{line, @deleted_fg, false}]
  defp style_diff_line(line), do: [{line, :default, false}]
end
