# Uninstalling Cosift

## The short way

```sh
curl -fsSL https://raw.githubusercontent.com/pilot-protocol/cosift-install/v1/install.sh | sh -s -- --uninstall
```

or, if you kept the script:

```sh
sh install.sh --uninstall
```

What it does:

1. Reads `${XDG_CONFIG_HOME:-~/.config}/cosift/state.json` for the list of harnesses it
   configured. If that file is missing, it falls back to looking for our entry in each of the
   three supported harnesses.
2. Removes the `cosift` entry from each of them. Other MCP servers are not touched.
3. Removes `state.json`.

It exits `0` when everything it named was removed, and non-zero otherwise. It does **not**
delete backup files, and it does **not** revoke the token — see
[Revoking a token](../README.md#revoking-a-token) in the README for that, and note that the
backups below still contain the token.

To see what it would do without doing it, add `--dry-run`.

## Manual removal

Use this if the installer is unavailable, if `--uninstall` reported a failure, or if you
simply prefer to do it yourself.

### Claude Code

Config file: `~/.claude.json`

Command:

```sh
claude mcp remove cosift --scope user
```

`--scope user` matters: without it the CLI looks in the local (per-directory) scope and will
report that no such server exists, even though the user-scoped one is still there.

Verify:

```sh
claude mcp list        # cosift should be gone
```

If you must edit the file by hand, the entry is the `"cosift"` key of the top-level
`mcpServers` object, and looks like this:

```json
"cosift": {
  "type": "http",
  "url": "https://cosift-mcp.pilotprotocol.network/v1/mcp",
  "headers": { "Authorization": "Bearer ck_..." }
}
```

Quit every running `claude` process first. `~/.claude.json` is Claude Code's live state file
and a running process will rewrite it from memory, discarding your edit. This is the reason
the installer itself never edits that file directly — it always goes through the CLI.

### Codex CLI

Config file: `~/.codex/config.toml`, or `$CODEX_HOME/config.toml` if you set `CODEX_HOME`.

There is no remove subcommand to use here — the installer wrote the block itself, between
markers, and you delete exactly that range. Open the file and delete these lines, the marker
comments included:

```toml
# >>> cosift (managed by cosift-install — do not edit)
[mcp_servers.cosift]
url = "https://cosift-mcp.pilotprotocol.network/v1/mcp"
[mcp_servers.cosift.http_headers]
Authorization = "Bearer ck_..."
# <<< cosift
```

The block is always at the end of the file and everything above it is untouched, so removing
it restores the file to exactly what it was before the install.

An equivalent one-liner (it writes a temp file and moves it into place, which works the same
on Linux and macOS, unlike `sed -i`):

```sh
awk '/^# >>> cosift/{s=1} !s{print} /^# <<< cosift/{s=0}' ~/.codex/config.toml > /tmp/codex.toml \
  && mv /tmp/codex.toml ~/.codex/config.toml
```

Verify:

```sh
codex mcp list                        # cosift should be gone
grep -n cosift ~/.codex/config.toml   # should print nothing
```

### opencode

Config file: `$XDG_CONFIG_HOME/opencode/opencode.json`, falling back to
`~/.config/opencode/opencode.json`. The file may also be named `opencode.jsonc`. On macOS the
path is the same — opencode uses `~/.config`, not `~/Library`.

**opencode has no `mcp remove` subcommand.** Adding is done through `opencode mcp add`;
removing has to be done by editing the file. (This asymmetry is also why the installer's own
uninstall path for opencode is the careful one: it backs the file up, edits it, validates the
result with `opencode mcp list`, and restores the backup if anything about that fails.)

Delete the `"cosift"` key and its whole value object from the `"mcp"` object. Given a file
like this:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  // my servers
  "mcp": {
    "some-other-server": {
      "type": "local",
      "command": ["some-server"]
    },
    "cosift": {
      "type": "remote",
      "url": "https://cosift-mcp.pilotprotocol.network/v1/mcp",
      "headers": { "Authorization": "Bearer ck_..." }
    }
  }
}
```

delete from the line containing `"cosift": {` through its matching closing `}` inclusive, and
then fix up the comma:

- if the `cosift` entry was last in `"mcp"`, also delete the comma at the end of the entry
  *before* it (the trailing comma after `}` on the `some-other-server` block above);
- if it was not last, delete the comma that followed its own closing `}`.

Leaving a doubled comma, or a comma immediately before the closing `}` of `"mcp"`, is
tolerated by opencode's JSONC parser but not by ordinary JSON tools, so it is worth fixing.
If `cosift` was the only entry, you can leave `"mcp": {}` or delete the `"mcp"` key entirely.

Two warnings about this file:

- It is **JSONC**: `//` and `/* */` comments and trailing commas are all legal in it. `jq` and
  Python's `json` module will reject a perfectly valid opencode config. Do not "fix" the file
  by running it through one of them — you will lose comments and formatting.
- Braces inside strings and inside comments are not structure. If you are scripting this, your
  brace matching has to be string-aware and comment-aware, or a `}` inside a comment will make
  you cut in the wrong place.

Verify:

```sh
opencode mcp list      # should exit 0 and no longer list cosift
```

If that command fails after your edit, restore your backup (below) and try again.

## Backup files

Every file the installer edits is copied first to:

```
<path>.cosift-backup-<UTC timestamp>
```

for example `~/.codex/config.toml.cosift-backup-20260412T091544Z`. The timestamp is UTC in
`YYYYmmddTHHMMSSZ` form, so the backups sort chronologically.

Find them:

```sh
ls -la ~/.claude.json.cosift-backup-* \
       ~/.codex/config.toml.cosift-backup-* \
       ~/.config/opencode/opencode.json*.cosift-backup-* 2>/dev/null
```

Restore one:

```sh
cp ~/.codex/config.toml.cosift-backup-20260412T091544Z ~/.codex/config.toml
```

(For `~/.claude.json`, quit every running `claude` process before restoring, for the same
reason as above.)

**The installer never deletes a backup**, including during `--uninstall`. They accumulate, one
per edit, and cleaning them up is left to you deliberately: an automatic cleanup is one bug
away from deleting the only copy of a config someone needed.

Two things to remember when you do clean them up:

- A backup taken from a config that already held a Cosift token **contains that token in
  cleartext**. Treat the files as secrets; delete them rather than archiving them.
- Deleting backups is not reversible. Check the current config is the one you want first.
