defmodule MingaGitExtended.UI.Picker.GitLogFileSource do
  @moduledoc "Browses commit history and patches restricted to one file in a repository."
  @behaviour MingaEditor.Extension.Picker.Source

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.Picker.Item
  alias MingaEditor.Extension.Picker.Source
  alias MingaGitExtended.UI.Picker.GitLogSource

  @typedoc "The absolute repository root and the repository-relative file path."
  @type args :: {Path.t(), Path.t()}

  @impl true
  @spec title() :: String.t()
  defdelegate title(), to: GitLogSource

  @impl true
  @spec candidates(args(), Source.page_request()) ::
          {:ok, [Item.t()], Source.next_page()} | {:error, String.t()}
  defdelegate candidates(args, page_request), to: GitLogSource

  @impl true
  @spec on_select(EditorAPI.state(), Item.t(), args()) :: EditorAPI.state()
  defdelegate on_select(state, item, args), to: GitLogSource

  @impl true
  @spec preview(Item.t(), args()) :: Source.preview()
  defdelegate preview(item, args), to: GitLogSource
end
