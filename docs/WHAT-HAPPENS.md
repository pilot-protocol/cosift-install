# What happens, step by step

This is the complete account of what `install.sh` does to your machine, what starts by itself
afterwards, what the agent reads, and what leaves the machine. It exists so that you can audit
every step rather than take a summary on trust.

Everything here is checkable against two files: `install.sh` and the `cosift-onboarding`
command, whose source the installer carries inside itself (`onboarding/bin/cosift-onboarding`
in this repository). The optional CLI handoff also invokes the already installed
[Cosift CLI](https://github.com/pilot-protocol/cosift). No code is fetched at runtime.

## 1. The install command

```sh
curl -fsSL https://raw.githubusercontent.com/pilot-protocol/cosift-install/v1/install.sh | sh
```

In order, the script:

1. Checks that `curl` exists and that `$HOME` is a writable directory.
2. Looks for `claude`, `codex` and `opencode` on your `PATH`, and for the Codex and opencode
   config files.
3. Asks which of the detected harnesses to configure (or takes `--harness=`, or `--yes`), then
   asks once whether to set Cosift up with you, naming every path it would write first
   (`--onboarding` and `--no-onboarding` answer that question up front).
4. Gets a credential: it scans the configs listed below for a `ck_…` token and offers each one
   to the Cosift MCP endpoint; the first the server accepts is reused. If none is, it asks for
   your email address and a six-digit code.
5. Writes the `cosift` MCP server entry into each selected harness config.
6. Installs onboarding, unless you declined it: one file per harness, the local command, and
   on Claude Code the hook and permission grants in `~/.claude/settings.json`.
7. Makes one MCP `initialize` call with the credential it just wrote, to prove the entry works.
8. If a compatible `cosift` binary is on `PATH`, passes the verified token to its
   `login` command through the subprocess environment. The CLI verifies it at
   `GET $COSIFT_COMMUNITY_URL/api/me` and creates a private origin-bound session.
   `--no-cli` skips this, and an existing session is never overwritten. No binary
   is downloaded. `--cli` makes an unavailable or unsuccessful CLI handoff an error.
9. Writes its state file and prints a summary of every path it touched.

`--dry-run` stops after step 3: it prints the per-harness plan, including the `settings.json`
line and the state of each interview path, and then exits without writing a byte under your
home directory and without ever running the email flow. It may make one read-only `initialize`
call with a credential already on the machine, to say whether that one would be reused.

### Files it reads

| Path | Why |
| --- | --- |
| `~/.claude.json` | find an existing `cosift` entry; recover a credential |
| `~/.codex/config.toml`, or `$CODEX_HOME/config.toml` | same |
| `$XDG_CONFIG_HOME/opencode/opencode.json[c]`, falling back to `~/.config/opencode/opencode.json[c]` | same |
| `${XDG_CONFIG_HOME:-~/.config}/cosift/state.json` | what a previous run configured |
| the interview paths in [section 2](#2-what-it-installs-for-the-interview) | whether a file is already there, and whether it is byte-identical to ours |

### Files it writes

| Path | What | Mode |
| --- | --- | --- |
| `~/.claude.json` | the `cosift` entry, via `claude mcp add --transport http --scope user` — the script never edits this file itself | unchanged, tightened to `0600` if it was group- or world-readable |
| `~/.codex/config.toml` | a marker-delimited `[mcp_servers.cosift]` block appended at the end | same |
| the opencode config above | the `cosift` entry, via `opencode mcp add` | same |
| `~/.claude/skills/cosift-onboarding/SKILL.md` | the interview, on Claude Code | `0644` |
| `${COSIFT_CODEX_SKILLS_DIR:-~/.agents/skills}/cosift-onboarding/SKILL.md` | the interview, on Codex | `0644` |
| `${XDG_CONFIG_HOME:-~/.config}/opencode/commands/cosift-onboarding.md` | the interview, on opencode | `0644` |
| `~/.local/bin/cosift-onboarding` | the local command described in [section 5](#5-cosift-onboarding-digest) | `0755` |
| `~/.claude/settings.json` | the hook and the permission grants in [section 3](#3-the-change-to-claudesettingsjson) | preserved; `0600` if the installer created the file |
| `${XDG_CONFIG_HOME:-~/.config}/cosift/state.json` | what was installed | `0600` |
| `${XDG_CONFIG_HOME:-~/.config}/cosift/community-session.json` | token, origin and expiry for the installed CLI; only if this file does not already exist | `0600` |
| `<each edited file>.cosift-backup-<UTC timestamp>` | a copy of the file as it was before the edit | `0600` |
| a directory under `$TMPDIR` | request bodies and curl header files, deleted on exit | `0700` |

Nothing outside those paths is written. Every file that is edited is copied to
`<path>.cosift-backup-YYYYmmddTHHMMSSZ` first, and backups are never deleted — not by a later
run, not by `--uninstall`.

**The three harness configs now hold your Cosift token in cleartext.** That is how MCP
authentication headers work in every harness supported here: the harness stores the literal
`Authorization: Bearer ck_…` header it has to send. Anything that can read your home directory
can read the token, and so can any backup taken after it was written.

### Network calls

The installer contacts the auth and MCP hosts, plus the community origin when
connecting an installed CLI:

| Request | To | Body |
| --- | --- | --- |
| `POST /auth/start` | `$COSIFT_AUTH_BASE` | the email address you typed |
| `POST /auth/verify` | `$COSIFT_AUTH_BASE` | the request id from the previous call and the six-digit code |
| `POST` the MCP endpoint | `$COSIFT_MCP_URL` | a JSON-RPC `initialize`, carrying the credential in a header |
| `GET /api/me` through the installed CLI | `$COSIFT_COMMUNITY_URL` | no body; the same credential in the authorization header |

`/auth/start` returns the same `200` for a deliverable address, an unknown one, a malformed one
and one over its cap, on purpose — a differing response would let anyone test whether an address
has a Cosift account. So neither the installer nor this document can tell you that an email was
sent.

There is no telemetry: no install ping, no analytics, no crash reporter, nothing about your
machine, your projects or your usage.

## 2. What it installs for the interview

One file per selected harness, plus one command:

| Harness | File |
| --- | --- |
| Claude Code | `~/.claude/skills/cosift-onboarding/SKILL.md` |
| Codex CLI | `${COSIFT_CODEX_SKILLS_DIR:-~/.agents/skills}/cosift-onboarding/SKILL.md` |
| opencode | `${XDG_CONFIG_HOME:-~/.config}/opencode/commands/cosift-onboarding.md` |
| all three | `~/.local/bin/cosift-onboarding`, the local command of [section 5](#5-cosift-onboarding-digest) |

These hold no credential. They are static text generated at release time: no timer, no
background process, nothing fetched while they run. If one of those paths is a symlink the
installer refuses it and leaves it, and whatever it points at, alone; if a file we did not write
is there, it is backed up before being replaced.

`--no-onboarding` skips all of it, including the settings change below. `--onboarding` installs
it without asking.

## 3. The change to `~/.claude/settings.json`

This is Claude Code only. Codex and opencode get no settings change: their plugin systems
install from a marketplace and from npm respectively, and neither can start something by itself.

The installer adds one hook and five permission strings to your user settings file. The hook is
what makes the interview start on its own; the permissions are what stop the agent asking you to
approve each call it makes during it.

### The hook

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

Claude Code runs that command at the start of every session and puts its output into the
session as context. The command is the same `cosift-onboarding` installed in section 2. It
makes no network call, writes nothing, and always exits `0` — a broken state file cannot break
your session.

### The permissions

```json
"permissions": {
  "allow": [
    "Bash(cosift-onboarding:*)",
    "mcp__cosift__cosift_search",
    "mcp__cosift__cosift_lookup",
    "mcp__cosift__cosift_request",
    "mcp__cosift__cosift_topics"
  ]
}
```

| Grant | What it allows |
| --- | --- |
| `Bash(cosift-onboarding:*)` | running the local `cosift-onboarding` command — `hook`, `status`, `digest` and `complete` — without a prompt. It is a prefix rule: it permits that one command name and nothing else |
| `mcp__cosift__cosift_search` | searching the Cosift corpus. Sends the query text |
| `mcp__cosift__cosift_lookup` | looking a subject up. Sends the subject text, which is recorded publicly — see [section 7](#7-what-becomes-public) |
| `mcp__cosift__cosift_request` | recording demand for a subject. Sends the subject text and a one-line reason the agent writes out of that subject's own approved words |
| `mcp__cosift__cosift_topics` | listing, adding and removing the topics your account follows. Sends the topic text |

The `mcp__cosift__` prefix is the MCP server name the installer used. If you renamed the server,
the grants do not match it and Claude Code asks before each call, which is the safe direction to
fail in.

### How the edit is made

The file is yours and shared with every other hook and permission you have, so it is never
rewritten in place. The installer adds its own entry if it is absent, removes its own entry on
uninstall, and leaves every other key exactly as it was. Before the edit the file is copied to
`~/.claude/settings.json.cosift-backup-<UTC timestamp>`; the new version is written to a
temporary file and renamed into place, with your file's own permission bits preserved.

It declines rather than guesses:

- with neither `python3` nor `node` available, `settings.json` is left untouched and the
  installer says so — a settings file full of other people's hooks is not something to edit
  with a regex. Onboarding still works; you type `/cosift-onboarding` to start it;
- if the file does not parse as JSON, or `hooks` or `permissions` is shaped in a way it does not
  recognise, the whole file is left alone and you get a warning.

### Removing the settings change

`install.sh --uninstall` removes both the hook and the five grants, and leaves the rest of the
file alone. A `cosift-onboarding` hook that is not the one we wrote is reported and left in
place, because removing something we did not install is not ours to do.

By hand: open `~/.claude/settings.json`, delete the `SessionStart` entry whose command ends in
`cosift-onboarding hook`, and delete those five strings from `permissions.allow`. Removing the
grants does not break anything — the agent goes back to asking you before each Cosift call.
Removing the hook alone turns off auto-start and leaves the interview available by typing
`/cosift-onboarding`.

## 4. The auto-start, and when it stays quiet

At session start Claude Code runs `cosift-onboarding hook`. That command reads the local state
file and prints this, and only this:

```text
Cosift is connected here but has not been set up yet.

If the user has not asked for anything specific in this session, run the
cosift-onboarding skill now, before saying anything else. If they have asked for
something, do that first and then tell them in one line, at the end, that Cosift is
not set up yet and you can do it whenever they like. Never do both in one turn, and
never mention this again in a session where you have already raised it.
```

So: open a session and say nothing, and the interview runs. Open a session with a question, and
the agent answers the question and adds one line at the end. It never does both in one turn.

It prints nothing at all, and the session proceeds as if it were not installed, when:

- you have completed the interview, or declined it — either is recorded locally by
  `cosift-onboarding complete`;
- the state file exists but cannot be parsed;
- the `cosift-onboarding` command has been removed — the hook is registered by absolute path,
  so your `PATH` does not affect it, though the interview does need `~/.local/bin` on `PATH` to
  run `digest` and to record that you are done;
- the hook is not in `settings.json`, or you are on Codex or opencode, where there is no
  auto-start at all.

Nothing about this is driven from Cosift's side. The trigger is a local hook reading a local
file; no Cosift tool call and no Cosift tool response points at the interview, and the server is
never told whether you have onboarded. The reasoning is in
[onboarding/docs/server-pointer-seam.md](../onboarding/docs/server-pointer-seam.md).

## 5. `cosift-onboarding digest`

The interview proposes subjects rather than interrogating you. It gets them from a local digest
of the sessions you have already had with your AI tools. Run it yourself to see exactly what the
agent sees:

```sh
cosift-onboarding digest            # 30 days
cosift-onboarding digest --days 90
```

It prints one short session title per line, newest first, and nothing else.

### What it reads

| Source | Where | What |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` | only the record whose `type` is `ai-title` — the title Claude Code generated for that session |
| opencode | `~/.local/share/opencode/opencode.db`, opened **read-only**, falling back to `~/.local/share/opencode/storage/session/*.json` | the `title` column of the `session` table |
| Codex | `$CODEX_HOME` or `~/.codex`, under `sessions/`, `history/`, `threads/`, `rollouts/` | a `title`, `aiTitle`, `summary` or `name` key in the first 200 lines of a session file |

The Codex row is best effort and **unverified**: no Codex build was available to check either
layout against, and finding nothing there is not treated as an error.

### What it deliberately does not read

- **Never the text of what you typed**, and never what the agent replied. Only the short title
  the tool generated for the session. On Claude Code that is one specific record type; a
  transcript is full of unrelated `title` keys belonging to tool calls, and those are not read.
- A title is **dropped**, not cleaned, if it contains a path (`/` or `~`), a URL (`http://`,
  `https://`, `www.`) or an email address. Those carry client, project and repository names.
- Placeholder titles (`new session`, `untitled`, `chat session` and the like) are dropped, as
  are titles under 6 or over 120 characters. Duplicates are folded case-insensitively.

The window is the last 30 days. If fewer than 15 titles fall inside it — a tool you use rarely —
it widens to the 60 most recent titles instead, so that there is something to work from.

Without `python3` the command falls back to an `awk` path that reads Claude Code's titles only,
under the same drop rules.

### What it does not do

It opens no socket and writes no file. Its output goes into the agent session that ran it, the
same as any other command output there. Nothing in it reaches Cosift except the subjects you
approve in the next step.

## 6. The interview

One step. The agent reads the digest, generalises each title into an ordinary public subject,
shows you one short list, and submits what you approve. You can edit any line, delete any line
or add your own; if the digest is empty it asks you instead.

**The generalisation is the point, not a formality.** Session titles carry client names, product
names, repository names and incident codenames. What is interesting about a session titled
"Acme billing migration" is *multi-tenant billing*, not *Acme*. Nothing identifiable is put in
front of you as a suggestion, and nothing identifiable is sent. If you add such a name yourself,
the agent says once that those exact words become public and offers the ordinary form.

The list comes in two labelled groups — the broad subjects to follow, and at most three worth
asking Cosift to write about — and the same message carries a short fixed block telling you that
it was drafted from a local summary of your recent session titles, that the summary stays on this
machine, and that Cosift receives only the lines you approve. That block is fixed text in
`onboarding/interview/BODY.md`, and a test pins that it is shown before anything is sent.

The interview may call these tools and no others:

| Tool | What it sends | What it writes |
| --- | --- | --- |
| `cosift_topics` | the subjects you approved, in one call | your account's followed-topics list. A follow is never written to the public ledger |
| `cosift_request` | an approved subject and a one-line reason built from that subject's own words | the subject text into the public demand ledger; the reason is stored on your account |
| `cosift_search` | a query string, and only if you ask it to find something | nothing public; the query still reaches Cosift's servers |
| `cosift_lookup` | a subject string, and only if you ask whether Cosift already has something | the subject text into the public demand ledger, which is why it shows you the string and waits for a yes first |
| `cosift-onboarding digest`, `status`, `complete` (local) | nothing — no network call | nothing, except that `complete` records the outcome in one local file under `${XDG_CONFIG_HOME:-~/.config}/cosift/` |

It does not read, list or search your files during the interview: the digest is the only thing
it reads, it reads it once, and on Claude Code the skill runs with `Read`, `Glob`, `Grep`,
`Write`, `Edit`, `NotebookEdit`, `WebFetch`, `WebSearch` and `Task` disallowed. `Bash` stays
enabled, because the digest and the completion record are local commands — so that fence is partial,
and [onboarding/docs/HARNESS-NOTES.md](../onboarding/docs/HARNESS-NOTES.md) says exactly how far
it goes on each harness.

One word declines, at any point. No Cosift call is made and nothing is sent. The agent says so
in one sentence and runs `cosift-onboarding complete --declined`, which writes that decline to
the local state file so the subject does not come up again.

## 7. What becomes public

**The link between your account and a subject is private. The words of the subject are not.**

- Every `cosift_lookup` and every `cosift_request` writes the literal subject text into Cosift's
  shared demand ledger: a global record of what people are asking for, holding the text, a
  counter and a timestamp. It is not linked to your account. **There is no delete path.** No
  tool in the interview, and none on the Cosift MCP surface, removes an entry from it.
- Followed topics stay on your account. `cosift_topics("remove", [...])` deletes a follow.
- A subject you *requested* is different: `remove` clears the follow markers but the account
  record survives, with the subject text, the time you asked and your reason line. Do not read
  `remove` as undoing a request.
- The one-line reason is stored on your account, not in the ledger, and cannot be deleted
  afterwards through any tool here.
- A search query reaches Cosift's servers even though search writes nothing to the ledger.
- If a subject is later covered, the resulting article and its title are public.

Which is the whole reason for the generalisation rule: keep client names, internal project names
and unreleased products out of it. Plain public words work best.

## 8. Undoing all of it

```sh
sh install.sh --uninstall
```

removes the `cosift` entry from every harness config, the interview files, the
`cosift-onboarding` command, the hook and the five permission grants from
`~/.claude/settings.json`, and the state files. It does **not** delete backups, and it does
**not** revoke the token server-side.

To do any of it by hand, including restoring a backup:
[docs/UNINSTALL.md](UNINSTALL.md). To revoke the token:
[Revoking a token](../README.md#revoking-a-token).

## 9. Checking this document against the source

| Claim here | Where to look |
| --- | --- |
| the install order, the prompts, the exit codes | `do_install`, `parse_args`, `usage` in `install.sh` |
| every path written, and the backup of each | `onboarding_path`, `onboarding_install`, `ensure_backup`, `write_state` in `install.sh` |
| the exact hook entry and the five permission strings | `claude_settings_merge` in `install.sh` — its argument list is the five strings, and the merge is the whole edit |
| that nothing else in `settings.json` is touched | `claude_settings_usable`, `claude_settings_install`, `claude_settings_remove` |
| the three network requests, and nothing else | `auth_start`, `auth_verify_loop`, `mcp_initialize` — the only callers of `http_post` |
| the token is never put in argv by curl | `mk_header_file`, and `curl -q -K` in `http_post` |
| what the digest reads and drops | `cmd_digest`, `py_digest`, `awk_digest` in `onboarding/bin/cosift-onboarding` |
| the exact auto-start text, and when it is silent | `cmd_hook`, and `cmd_status` for the state words |
| what the interview may say and do | `onboarding/interview/BODY.md`, which is what the installed file is generated from |

The installed interview file is byte-identical to what the installer carries; `tests/run.sh`
compares them inside a container on every run.
