# GitExtended

GitExtended adds a Git status sidebar, staging and commits, branch and stash management, diff views, and conflict resolution to Minga. Minga's built-in Git indicators work without it.

## Install

Use a Minga build with the source-owned Git workflow APIs from SDK 0.1.1. Add this to your Minga `config.exs` and restart:

```elixir
extension :minga_git_extended, git: "https://github.com/jsmestad/minga-git-extended"
```

Open a file in a Git repository and press `SPC g g` to open Git Status. In the terminal, use `j` and `k` to select a row and `p` to preview its diff. On macOS, right-click a file in the sidebar and choose **Open Diff**. Use the **Stage hunk** command to stage only the selected change.

`SPC g f` opens the changed-file picker, `SPC g l` opens the log, and `SPC g B` opens the branch picker. Remove the configuration line and restart to disable GitExtended.

## Develop

Use the Elixir and OTP versions in `.tool-versions`. To check the extension against the published SDK without loading the editor:

```sh
mix deps.get
mix compile --warnings-as-errors
```

For integration tests, use a compatible Minga source checkout. The tests start an isolated host and do not use your normal Minga configuration.

```sh
MINGA_HOST_SOURCE=/path/to/minga MIX_ENV=test mix deps.get
MINGA_HOST_SOURCE=/path/to/minga mix test
```

Set `MINGA_SDK_PATH` to a local SDK checkout when validating against an unpublished SDK candidate.
