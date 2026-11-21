defmodule MingaGitExtended.UI.Picker.GitLogSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Git.LogEntry
  alias Minga.Git.Stub
  alias MingaEditor.Extension.Picker.Item
  alias MingaGitExtended.UI.Picker.GitLogFileSource
  alias MingaGitExtended.UI.Picker.GitLogSource

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    on_exit(fn -> Stub.clear(root) end)
    %{root: root}
  end

  test "pagination keeps the original head and excludes the continuation from the commit items",
       %{root: root} do
    commits = Enum.map(1..52, &entry/1)
    [head | _] = commits
    revision = head.hash
    Stub.set_log(root, [count: 1], [head])
    Stub.set_log(root, [count: 51, revision: revision, skip: 0], Enum.take(commits, 51))
    Stub.set_log(root, [count: 51, revision: revision, skip: 50], Enum.drop(commits, 50))

    assert {:ok, items, {:more, {^revision, 50} = cursor, %Item{label: "Load more..."}}} =
             GitLogSource.candidates(root, :start)

    assert length(items) == 50

    assert [
             %Item{
               label: "Commit 1",
               description: "Ada · today",
               annotation: "1",
               search_text: match
             }
             | _
           ] = items

    assert match =~ revision
    assert match =~ "Ada"

    Stub.set_log(root, [count: 1], [entry(99)])
    assert {:ok, resumed, :done} = GitLogSource.candidates(root, {:continue, cursor})
    assert Enum.map(resumed, & &1.label) == ["Commit 51", "Commit 52"]
  end

  test "file log restricts subsequent history and previews to the captured path", %{root: root} do
    path = "lib/demo.ex"
    head = entry(1)
    older = entry(51)
    Stub.set_log(root, [count: 1], [head])
    Stub.set_log(root, [count: 51, revision: head.hash, skip: 50, path: path], [older])
    Stub.set_log(root, [count: 51, revision: head.hash, skip: 50], [entry(99)])

    assert {:ok, [item], :done} =
             GitLogFileSource.candidates({root, path}, {:continue, {head.hash, 50}})

    assert item.id == older.hash

    Stub.set_diff(root, [commit: older.hash], "+unrelated")
    Stub.set_diff(root, [commit: older.hash, path: path], "@@ -1 +1 @@\n-old\n+new")

    assert {:lines, [[{"@@ -1 +1 @@", _, true}], [{"-old", _, false}], [{"+new", _, false}]]} =
             GitLogFileSource.preview(item, {root, path})
  end

  defp entry(number) do
    %LogEntry{
      hash: number |> Integer.to_string(16) |> String.pad_leading(40, "0"),
      short_hash: Integer.to_string(number),
      author: "Ada",
      date: "today",
      message: "Commit #{number}"
    }
  end
end
