# Harness notes

What was checked, how, and what is still a guess. Verified 2026-09-16 against the official
docs and the binaries named below.

## The table

| harness | the one installed file | frontmatter keys allowed | invocation | auto-start | `verified` |
| --- | --- | --- | --- | --- | --- |
| claude | `$HOME/.claude/skills/cosift-onboarding/SKILL.md` | `name`, `description`, `user-invocable`, `disallowed-tools` | `/cosift-onboarding` | yes, `SessionStart` hook | true |
| codex | `${COSIFT_CODEX_SKILLS_DIR:-$HOME/.agents/skills}/cosift-onboarding/SKILL.md` | `name`, `description` and nothing else | `$cosift-onboarding` | no | false |
| opencode | `${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands/cosift-onboarding.md` | `description` | `/cosift-onboarding` | no | true |
| hermes | `${HERMES_HOME:-$HOME/.hermes}/skills/cosift-onboarding/SKILL.md` | `name`, `description`, `version`, `metadata` | `/cosift-onboarding` | no | false |

`install.sh` installs the first three. The hermes row is a profile contract and nothing more —
see [Hermes is not installed](#hermes-is-not-installed) below.

`verified` is the boolean in `onboarding/profiles/<harness>.json` and in
`onboarding/generated/MANIFEST.json`. It means one thing only: the install path and the
frontmatter key set were checked against a harness binary installed **on the build host**. It
is not a claim about discovery, and it is not a claim about the container runs below. Neither
file is read at install time; both are build-tree records.

The generator refuses to emit a frontmatter key set that differs from a profile's
`allowed_frontmatter_keys`, and refuses any codex key other than `name` and `description`.
`onboarding/tests/shell/cases/10-drift.sh` re-checks the emitted keys against the profile and
the manifest. `tests/run.sh` goes further inside a container: it compares each installed file
against `onboarding/generated/<harness>/` byte for byte, so the frontmatter cannot differ.

## What was observed in the test container, 2026-09-16

`tests/Dockerfile`: image `node:22-bookworm-slim`, throwaway `HOME=/home/tester`, run with
`--network none`. CLIs pinned at build time: claude 2.1.273, codex-cli 0.154.0,
opencode 1.18.31. `tests/run.sh` case C46 is the discovery case.

- **opencode: discovery proven.** `opencode serve --pure` was started inside the container and
  `GET /command` over loopback listed `cosift-onboarding` with `source: command` and the exact
  description from the installed frontmatter.
- **codex: discovery proven.** `codex debug prompt-input` renders the model-visible prompt
  offline. The `skills_instructions` block listed `- cosift-onboarding: <description>` with
  the installed description, resolved from the `~/.agents/skills` root. The codex profile
  still says `verified: false` because codex is not installed on the build host, which is what
  that flag records.
- **claude: discovery UNPROVEN.** Claude Code 2.1.273 exposes no no-auth listing of installed
  skills. `claude doctor` and `claude plugin list` were both probed and neither mentions the
  artifact. The run prints `DISCOVERY: UNPROVEN (claude)` and counts a SKIP. It is deliberately
  not downgraded into a weaker assertion that would look green.
- **hermes: nothing.** No Hermes binary exists to test against, and `install.sh` does not
  install it, so there was nothing to exercise.

opencode's external-skill scan can also see the claude and codex artifacts. That was a second
reader agreeing about the path and the frontmatter, observed by hand on the date above. No
case in `tests/run.sh` re-checks it.

## Auto-start: the `SessionStart` hook

Claude Code runs every command registered under `hooks.SessionStart` in `~/.claude/settings.json`
when a session starts, and feeds the command's stdout into that session as context. That is the
entire mechanism; there is nothing Cosift-specific in it, and nothing on the server side is
involved.

The installer registers one entry, `cosift-onboarding hook`, by **absolute path** — a hook does
not inherit the user's interactive `PATH`, and `~/.local/bin` is frequently not on it.

`cmd_hook` in `onboarding/bin/cosift-onboarding` is deliberately dull:

- it runs `cmd_status` in a command substitution and reads the single word;
- it prints the directive for `pending` and for `unknown` (no state file: Cosift may have been
  configured by hand), and prints nothing for `done`, `declined` or `malformed`;
- it always exits 0. `cmd_status` exits non-zero for `done`/`declined`/`malformed`, but that
  happens inside the subshell and never reaches the harness. A broken state file must not break
  someone's session.

The directive it prints is instruction text for the model, not an action: run the skill only if
the user has asked for nothing this session, otherwise do their work and mention Cosift in one
line at the end, never both in one turn, never twice in a session.

Alongside it the installer adds five strings to `permissions.allow`: `Bash(cosift-onboarding:*)`
plus `mcp__cosift__cosift_search`, `..._lookup`, `..._request` and `..._topics`. Without them the
harness stops to ask for each call, which is the friction this design exists to remove. The MCP
names embed the server name chosen at install time — always `cosift` from this installer — so a
user who renamed the server simply gets the prompts back, which is the safe direction to fail in.

**Why codex and opencode cannot do this.** Neither has a user-level "run this at session start"
surface an installer can write from a shell script. Codex plugins install from a marketplace, and
opencode plugins are npm modules resolved by the harness; in both cases auto-start would mean
shipping and publishing a package through someone else's distribution channel, which is a
different artifact from the single static file this installer writes. Both therefore stay
type-to-start, and the capability difference is stated plainly in the user-facing documents
rather than papered over.

## Where the session titles come from

`cosift-onboarding digest` reads the title each harness generates for a session. It never reads
conversation text, and it opens no socket.

| harness | store | the record |
| --- | --- | --- |
| claude | `$HOME/.claude/projects/**/*.jsonl` | the line whose `type` is `ai-title`, field `aiTitle` (falling back to `title` on that same record). The file's mtime is the recency key |
| opencode | `$HOME/.local/share/opencode/opencode.db` | `select title, time_created from session`, opened read-only (`?mode=ro`, then `?mode=ro&immutable=1`) so the live database is never touched as a writer. Fallback: `storage/session/*.json`, `time.updated` or `time.created` |
| codex | `$CODEX_HOME` or `$HOME/.codex`, under `sessions/`, `history/`, `threads/`, `rollouts/` | first `title`, `aiTitle`, `summary` or `name` key in the first 200 lines of a session file. **Unverified**: no codex build was available to check either layout, and finding neither is not an error |
| hermes | — | not read |

Claude Code's transcripts are full of unrelated `title` keys belonging to tool calls, which is
why only the one record type is matched: a looser match would emit arbitrary conversation text.

Filtering, in `py_digest`: a title is dropped, not cleaned, when it contains a path, a URL or an
address; when it is under 6 or over 120 characters; or when it is one of the harnesses'
placeholder titles. Duplicates fold case-insensitively. The window is `--days` (default 30), and
widens to the 60 most recent titles when fewer than 15 fall inside it, so a rarely used harness
still yields something. Empty output with exit 0 means "no history", which is the interview's
signal to ask questions instead.

Without python3 the command falls back to an awk path that reads Claude Code only, matching the
same `ai-title` record and applying the same drop rules.

## Ambiguity 1: codex, `~/.agents/skills` against `~/.codex/skills`

The codex documentation is in conflict with itself. `~/.agents/skills` is the current official
location; `~/.codex/skills` appears in legacy and bundled material. We install to
`~/.agents/skills` and never write to `~/.codex/skills`.

Override for anyone whose build disagrees:

```sh
COSIFT_CODEX_SKILLS_DIR=/some/other/skills ./install.sh --onboarding
```

There is no flag for this; the environment variable is the whole interface. Both `install.sh`
and `cosift-onboarding paths` read it, so exporting it once keeps the two in step. The leaf is
still `cosift-onboarding/SKILL.md` under whatever directory you name.

## Ambiguity 2: opencode, `command/` against `commands/`

opencode scans **both** `command/` and `commands/`, recursively, under its config directory.
Two files with the same base name therefore register the same command name twice. We install
to `commands/` (plural).

If `${XDG_CONFIG_HOME:-$HOME/.config}/opencode/command/cosift-onboarding.md` already exists,
the installer prints a warning, names that exact path, explains the collision, and skips the
interview for opencode. Only for opencode: the other harnesses are still configured and the run
still exits 0. There is no flag that installs over it — rename or remove the rival file and
re-run with `--onboarding`. `--dry-run` reports the same thing before the fact. The rival file
is never read, modified or removed.

## Hermes is not installed

`install.sh` does not configure Hermes. It accepts `--harness=claude`, `--harness=codex` and
`--harness=opencode` and rejects anything else, and nothing in it writes under
`${HERMES_HOME:-$HOME/.hermes}`. `onboarding/profiles/hermes.json` and the generated
`onboarding/generated/hermes/` artifact are retained only as a record of the contract, for a
release that adds Hermes.

Nothing about Hermes was checked against a running Hermes either: not the install path, not the
frontmatter keys, not the invocation string. The record says so:

- the Hermes artifact carries a banner in its generated prefix saying UNVERIFIED, naming the
  version, and stating that Hermes performs no argument substitution;
- `onboarding/profiles/hermes.json` and the manifest carry `verified: false`, which
  `onboarding/tests/shell/cases/10-drift.sh` asserts.

Hermes performs no argument substitution, so anything typed after the invocation arrives as
ordinary text. The interview body therefore never depends on `$ARGUMENTS` having been
substituted, and treats any such text as one more thing the user is interested in, never as
approval of a list they have not seen. That rule is in the body for every harness, not only for
Hermes.

## Why `disallowed-tools` and not `allowed-tools` on Claude Code

MCP tool names are namespaced by the server name the user chose at install time, so the Cosift
tools are only called `mcp__cosift__cosift_search` when the user happened to name the server
`cosift`. An allowlist would break the interview for every other name. The claude profile
therefore uses `disallowed-tools` and leaves the MCP surface alone. The emitted value is:

```yaml
disallowed-tools: Read, Glob, Grep, Write, Edit, NotebookEdit, WebFetch, WebSearch, Task
```

That is the whole fence, and it is worth saying exactly what it is not.

**`Bash` is not on the list.** It is the one filesystem-and-network tool left enabled, and it
is left enabled on purpose: the interview runs `cosift-onboarding digest`, `status` and
`complete`, and there is no way in this key to permit those and deny the rest of a shell. So on
Claude Code the fence is partial. A model that decided to ignore the body's hard rules could
still reach a file or the network through `Bash`. Two alternatives were considered and rejected:

- Denying `Bash` outright. That closes the fence completely, and it also removes the digest —
  the reason the interview is one step rather than an interrogation — along with the completion
  record that stops it starting again. The body degrades cleanly when the command is missing, so
  this stays on the table, but it trades the feature for a fence codex and opencode do not have
  either.
- Adding scoped entries such as `Bash(curl:*)`, `Bash(cat:*)`. That form was never verified
  against a running Claude Code skill loader, and an enumerated list of forbidden commands
  teaches that everything not enumerated is fine — the same failure mode the body's closed rule
  about tool-response strings exists to avoid. A fence that looks stronger than it is would be
  worse than an honest partial one.

The `Bash(cosift-onboarding:*)` grant in `settings.json` is not a second fence: it decides what
runs without a prompt, not what the model is able to run.

`NotebookEdit` was added to the list because it is a writer and nothing else fenced it.

Codex and opencode have no equivalent key at all, so on those the constraint lives only in the
body's hard rules. That is a real difference in enforcement strength, and it is why the rule
that the digest is the only thing the interview reads sits at the top of the body rather than
in a note further down. `onboarding/docs/ONBOARDING.md` states all of this in the user-facing
wording, and `onboarding/tests/shell/cases/20-structural.sh` asserts that the string quoted in
both documents is byte-identical to the one the generator emits, so they cannot drift apart.
