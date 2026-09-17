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
   configured. If that file is missing, or names no harness, it falls back to looking for our
   entry in each of the three supported harnesses.
2. Removes the `cosift` entry from each of them. Other MCP servers are not touched.
3. Removes the onboarding interview file, and then the `cosift-onboarding` directory it created
   for that file, only if that directory is empty — a `.cosift-backup-*` file left in there
   keeps it from being empty, so the directory stays. A file we wrote, this release's or an
   earlier release's, is removed as it is; a file at one of those paths that we did not write is
   backed up before it is removed.
4. Removes `~/.local/bin/cosift-onboarding`, but only if that file is byte-identical to the one
   it installed. If it is not — an older release's copy, or one you edited — it says so and
   leaves the file; remove it by hand.
5. Removes the entries it added to `~/.claude/settings.json`: the `SessionStart` hook and the
   five permission grants. Nothing else in that file is touched.
6. Removes `state.json`, and `onboarding.json` beside it.

It does not trust the state file for step 3: it checks all three interview paths directly and
removes whatever it recognises as ours. A file left behind by an earlier run is still found,
and re-running after you fix a permission problem still clears it.

It exits non-zero when it cannot remove a `cosift` entry from a harness config, or cannot
remove `state.json`; the state file is left in place so you can retry. A failure to remove an
interview file, the `cosift-onboarding` command or `onboarding.json` is only a warning: the run
names the file it could not remove and can still exit `0`. Read the output, not just the exit
code.

It does **not** delete backup files, and it does **not** revoke the token — see
[Revoking a token](../README.md#revoking-a-token) in the README for that, and note that the
backups below still contain the token.

There is no uninstall preview: `--dry-run` with `--uninstall` is a usage error and exits `2`.

The Cosift CLI binary and `${XDG_CONFIG_HOME:-~/.config}/cosift/community-session.json`
are left available for independent CLI use. Run `cosift logout` to revoke and
remove that session. This also invalidates the same token in any remaining
agent configuration; it does not revoke other tokens belonging to the account.

## Manual removal

Use this if the installer is unavailable, if `--uninstall` reported a failure or a warning, or
if you simply prefer to do it yourself.

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
  "url": "https://cosift-mcp-udik5erlkq-uw.a.run.app/v1/mcp",
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
url = "https://cosift-mcp-udik5erlkq-uw.a.run.app/v1/mcp"
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
      "url": "https://cosift-mcp-udik5erlkq-uw.a.run.app/v1/mcp",
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

## Removing the onboarding interview

Skip this if you declined the interview when you installed — in that case nothing below was
ever written. `${XDG_CONFIG_HOME:-~/.config}/cosift/state.json` lists what was installed, under
`onboarding_installed` and `onboarding_cmd`. Both keys are always there; declining leaves them
`[]` and `""`.

One file per harness, and one directory per file except on opencode:

| Harness | The file | The directory we created |
| --- | --- | --- |
| Claude Code | `~/.claude/skills/cosift-onboarding/SKILL.md` | `~/.claude/skills/cosift-onboarding` |
| Codex CLI | `${COSIFT_CODEX_SKILLS_DIR:-~/.agents/skills}/cosift-onboarding/SKILL.md` | that file's parent directory |
| opencode | `${XDG_CONFIG_HOME:-~/.config}/opencode/commands/cosift-onboarding.md` | none |

Note that Codex's skills root is `~/.agents/skills`. It is not under `$CODEX_HOME`, so if you
moved `CODEX_HOME` the skill is still in `~/.agents` — unless you set
`COSIFT_CODEX_SKILLS_DIR` at install time, in which case it is under that.

**The directory rule:** remove the `cosift-onboarding` directory, and only when it is empty.
Never remove `~/.claude/skills`, the Codex skills root, or opencode's `commands/`. Those hold
every other skill and command you have — the installer creates them when they are missing, but
they are shared, so it leaves them behind even when our file was the only thing in them. The
`cosift-onboarding` directory is ours alone, so that one goes. On opencode there is no directory
of ours at all — the file sits directly in the shared `commands/` directory.

Claude Code:

```sh
rm -f ~/.claude/skills/cosift-onboarding/SKILL.md
rmdir ~/.claude/skills/cosift-onboarding      # refuses if anything else is in there
```

Codex CLI:

```sh
rm -f ~/.agents/skills/cosift-onboarding/SKILL.md
rmdir ~/.agents/skills/cosift-onboarding
```

opencode — no `rmdir`, because `commands/` is not ours:

```sh
rm -f ~/.config/opencode/commands/cosift-onboarding.md
```

If `rmdir` refuses, list the directory before you force anything: a `.cosift-backup-*` file we
took there is enough to keep it alive, and the installer never deletes one. That is also why
`--uninstall` can leave the directory behind.

Then the local command, which is shared by all three:

```sh
rm -f ~/.local/bin/cosift-onboarding
```

Verify with `ls`: the file being gone is the check. Claude Code has no subcommand that lists
installed skills, so there is nothing else to ask.

Restart any harness that was running while you deleted the file.

### The Claude Code settings entries

On Claude Code the installer also edited `~/.claude/settings.json`. Two things went in there,
and this file has no marker comments, so remove them by name.

**The hook**, which is what starts onboarding by itself. Under the top-level `"hooks"` key,
inside `"SessionStart"`, delete the entry whose command ends in `cosift-onboarding hook`:

```json
"hooks": {
  "SessionStart": [
    {
      "hooks": [
        { "type": "command", "command": "/home/you/.local/bin/cosift-onboarding hook" }
      ]
    }
  ]
}
```

Delete that one object from the `"SessionStart"` array. If it was the only entry, you can leave
`"SessionStart": []` or delete the `"SessionStart"` key; if `"hooks"` is then empty, that key
can go too. Deleting only this is enough to stop the auto-start while leaving the interview
available by typing `/cosift-onboarding`.

**The five permission grants**, under `"permissions"` → `"allow"`. Delete exactly these
strings, and nothing else in that array:

```json
"Bash(cosift-onboarding:*)"
"mcp__cosift__cosift_search"
"mcp__cosift__cosift_lookup"
"mcp__cosift__cosift_request"
"mcp__cosift__cosift_topics"
```

Removing them breaks nothing: Claude Code goes back to asking you before each of those calls.
Mind the commas — `settings.json` is strict JSON, not JSONC, so a trailing or doubled comma
makes the whole file unreadable to Claude Code.

The four `mcp__cosift__*` strings are named after the MCP server, which this installer always
calls `cosift`. If you renamed the server, your grants carry that other name instead.

Verify by reading the file back:

```sh
grep -n "cosift" ~/.claude/settings.json      # should print nothing
```

If you installed with `--no-onboarding`, none of this was ever written and there is nothing
here to remove. The same is true if the installer reported that it was leaving `settings.json`
alone: it edits that file only with `python3` or `node`, and only when the file parses and its
`hooks` and `permissions` sections are shaped the way it expects.

`--uninstall` takes out the entry it wrote and nothing else. A `cosift-onboarding` hook that is
*not* the one it wrote is named in a warning and left in place — that one is yours to remove,
here.

Restart Claude Code after editing the file.

### The local state file

The interview records locally that you finished it, or that you declined, so that it does not
ask again. That record is one of two files, depending on what existed at the time:

```sh
rm -f ~/.config/cosift/state.json ~/.config/cosift/onboarding.json
```

If you set `XDG_CONFIG_HOME`, both files are under it rather than under `~/.config`, as are
opencode's config and its `commands/` directory above.

`state.json` is the installer's own file. `onboarding.json` is written by
`cosift-onboarding complete` only when there is no `state.json` to write into — which is why
removing just `state.json` can leave the flag behind in the second file. Remove both. `rm -f`
says nothing about the one that is not there.

`cosift-onboarding complete` also leaves one backup of whichever of the two files it rewrote,
named the same way as every other backup here. It keeps one, not one per run. Delete it too if
you want the directory clean:

```sh
rm -f ~/.config/cosift/state.json.cosift-backup-* \
      ~/.config/cosift/onboarding.json.cosift-backup-*
rmdir ~/.config/cosift          # only succeeds once the directory is empty
```

These files never contain the token.

## Backup files

Every file the installer edits is copied first to:

```
<path>.cosift-backup-<UTC timestamp>
```

for example `~/.codex/config.toml.cosift-backup-20260412T091544Z`. The timestamp is UTC in
`YYYYmmddTHHMMSSZ` form, so the backups sort chronologically.

The same naming covers a file that was already sitting at one of the onboarding paths: it is
copied before we replace it, and copied again before `--uninstall` removes it, unless it is one
of ours — this release's copy or an earlier release's — in which case there is nothing of yours
to preserve. A `cosift-onboarding` command that was not ours is copied the same way before it
is replaced; `--uninstall` does not remove that one at all. On
opencode those copies land in the shared `commands/` directory, which is where to look for a
stray `cosift-onboarding.md.cosift-backup-...` later.

Find them:

```sh
ls -la ~/.claude.json.cosift-backup-* \
       ~/.claude/settings.json.cosift-backup-* \
       ~/.codex/config.toml.cosift-backup-* \
       ~/.config/opencode/opencode.json*.cosift-backup-* \
       ~/.claude/skills/cosift-onboarding/SKILL.md.cosift-backup-* \
       ~/.agents/skills/cosift-onboarding/SKILL.md.cosift-backup-* \
       ~/.config/opencode/commands/cosift-onboarding.md.cosift-backup-* \
       ~/.local/bin/cosift-onboarding.cosift-backup-* \
       ~/.config/cosift/state.json.cosift-backup-* \
       ~/.config/cosift/onboarding.json.cosift-backup-* 2>/dev/null
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
  cleartext**. Treat the files as secrets; delete them rather than archiving them. A backup
  taken from an onboarding path holds whatever was at that path before — never a token of ours,
  but read it before you delete it if you did not put it there yourself.
- Deleting backups is not reversible. Check the current config is the one you want first.
