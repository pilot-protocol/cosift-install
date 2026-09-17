# cosift-install

Cosift is a curated reference corpus that an AI agent can consult while it works — a
Wikipedia for agents: instead of guessing from memory, the agent looks a subject up and
grounds its answer in the curated article. Cosift is exposed to agents as a remote MCP
server. This repository contains `install.sh`, a single POSIX shell script that registers
that server (named `cosift`) in the AI harnesses you already have installed and stores the
credential they need to reach it.

The script is one file. It is short enough to read in a few minutes, and reading it before
you run it is a reasonable thing to do.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/pilot-protocol/cosift-install/v1/install.sh | sh
```

It detects which supported harnesses are present, asks which of them to configure, gets you
a credential (by emailing you a six-digit code, unless a usable Cosift credential is already
on the machine), writes the server entry, and verifies that the entry actually works before
it reports success. If you agree to it, it also installs a short [onboarding
interview](#the-onboarding-interview) that your agent can run.

Supported harnesses: **Claude Code**, **Codex CLI**, **opencode**.

Supported platforms: Linux and macOS.

## What this does to your machine

Nothing happens outside the paths listed here. Run with `--dry-run` first if you want the
exact per-harness plan for your machine printed without a byte being written under your home
directory.

### Files it reads

| Path | Why |
| --- | --- |
| `~/.claude.json` | detect an existing Cosift entry; recover an existing credential |
| `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) | same |
| `$XDG_CONFIG_HOME/opencode/opencode.json` or `.jsonc`, falling back to `~/.config/opencode/opencode.json` or `.jsonc` (on macOS too — opencode uses `~/.config`, not `~/Library`) | same |
| `${XDG_CONFIG_HOME:-~/.config}/cosift/state.json` | what a previous run configured |
| the onboarding interview paths listed [below](#what-it-installs) | whether a file is already sitting there, and whether it is byte-identical to ours |

It also looks for `claude`, `codex` and `opencode` on your `PATH`.

The credential scan is how a second install on the same machine skips the email step: any
`ck_…` token found in those files is offered to the Cosift server, and the first one the
server accepts is reused.

### Files it writes

| Path | What |
| --- | --- |
| `~/.claude.json` | the `cosift` entry, written by `claude mcp add --transport http --scope user` — the script never edits this file itself |
| `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) | a marker-delimited `[mcp_servers.cosift]` block appended to the end; nothing else in the file is touched |
| the opencode config named above | the `cosift` entry, written by `opencode mcp add` — the script never edits this file when adding |
| `<each edited file>.cosift-backup-<UTC timestamp>` | a copy of the file as it was before the edit |
| `${XDG_CONFIG_HOME:-~/.config}/cosift/state.json` | what was installed, mode `0600` |
| one file per selected harness, named under [the onboarding interview](#the-onboarding-interview) | the interview itself, mode `0644` — only if you agree to it |
| `~/.local/bin/cosift-onboarding` | the local command the interview uses, mode `0755` — same condition |
| a temporary directory under `$TMPDIR` | request bodies and header files, deleted on exit |

Every file the script edits is copied to `<path>.cosift-backup-YYYYmmddTHHMMSSZ` **before**
the edit. Backups are never deleted, not even by `--uninstall`. See
[docs/UNINSTALL.md](docs/UNINSTALL.md) for how to restore one.

`state.json` contains the installer version, the account id (empty when the credential was
recovered rather than minted), which harnesses were configured, an `onboarded` flag, the
install timestamp, which harnesses received the interview (`onboarding_installed`) and the
path of the local command (`onboarding_cmd`). Those last two are always written: decline the
interview and they are `[]` and `""`. It does not contain the token.

If an existing config cannot be modified safely — for example your `config.toml` already
declares an `[mcp_servers.cosift]` table that the installer did not write — the script
refuses and exits `5` rather than overwriting it.

### Network

The script contacts exactly two hosts: the Cosift auth service (`COSIFT_AUTH_BASE`) and the
Cosift MCP endpoint (`COSIFT_MCP_URL`), both shown in `--help`. It sends your email address
to the auth service in order to email you a code, and it sends the credential to the MCP
endpoint to check that it works.

There is **no telemetry**. Nothing about your machine, your harnesses, your projects, or your
usage is collected or transmitted. There is no analytics call, no install ping, no crash
reporter.

## Security note: your harness config now holds a credential

After a successful install, **your AI harness's config file contains a Cosift API token in
cleartext.** This is not a design choice we made lightly — it is how MCP authentication
headers work in every harness we support: the harness stores the literal
`Authorization: Bearer ck_…` header it must send.

The files that hold it are:

- Claude Code — `~/.claude.json`
- Codex CLI — `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`)
- opencode — `$XDG_CONFIG_HOME/opencode/opencode.json[c]`, else `~/.config/opencode/opencode.json[c]`

Consequences worth taking seriously:

- **Do not commit these files**, and do not paste them into an issue, a gist, or a chat. If
  you keep dotfiles in git, exclude them or strip the header before committing.
- Anything that can read your home directory can read the token. Backups, sync clients, and
  screen shares included.
- The `.cosift-backup-*` files also contain a token if the file did when the backup was
  taken. Delete them once you no longer need them.
- The token is never printed in full by the installer. When it must be shown it is truncated
  to at most eight characters, like `ck_1_ABCD…`.

If a token leaks, revoke it — see [Revoking a token](#revoking-a-token).

## The onboarding interview

The installer can also install a short interview that your agent runs when you ask it to. The
interview asks two to four questions about what you work on and turns your answers into two
things: **topics your account follows**, and **at most three coverage requests**. A request
records demand for an article. It is not a promise that one gets written.

It is installed only if you agree to it. With no flag and a terminal available, the installer
lists the exact files it would write and asks once, `[Y/n]`, after you have chosen your
harnesses; bare Enter means yes. Answer `n` and nothing is written. With no terminal available
— some CI runners, some container invocations — it is skipped without a prompt, and the
installer prints one line telling you that `--onboarding` adds it later. Pass `--no-onboarding`
to decline up front. `--yes` implies `--onboarding`.

Agreeing to install it is not agreeing to run it. Inside the interview your agent asks again,
with a disclosure, before anything is recorded with Cosift.

### What it installs

One file per harness you selected:

| Harness | File |
| --- | --- |
| Claude Code | `~/.claude/skills/cosift-onboarding/SKILL.md` |
| Codex CLI | `${COSIFT_CODEX_SKILLS_DIR:-~/.agents/skills}/cosift-onboarding/SKILL.md` |
| opencode | `${XDG_CONFIG_HOME:-~/.config}/opencode/commands/cosift-onboarding.md` |

Codex reads skills from `~/.agents/skills`, which is **not** under `$CODEX_HOME`; setting
`CODEX_HOME` does not move it. `COSIFT_CODEX_SKILLS_DIR` does.

Plus one command, `~/.local/bin/cosift-onboarding`, mode `0755`.

**None of these files holds a credential.** Unlike the harness configs above, there is no token
in them and nothing in them is secret — they are mode `0644`, and the installer leaves them
that way on purpose. Directories it creates for them are `0755`: the `cosift-onboarding`
directory, the skills or commands directory above it, and `~/.local/bin`. Anything further up
that it has to create (`~/.claude`, `~/.agents`, `~/.config/opencode`, `~/.local`) comes out
`0700`. They are static text generated at release time: no timer, no background process,
nothing fetched while they run.

If one of those paths already has something in it:

- byte-identical to what we would write — nothing happens, and the installer says "already up
  to date";
- an interview of ours from an earlier release — it is replaced in place, with no backup;
- a symlink — it is refused and left alone, and so is whatever it points at;
- anything else — it is copied to `<path>.cosift-backup-<UTC timestamp>` first, then replaced,
  and the installer tells you it did that.

If any part of this fails you get a warning, not a failed install. By that point the MCP server
is registered and verified, and a missing interview is not a reason to undo that.

### How to run it

| Harness | Type |
| --- | --- |
| Claude Code | `/cosift-onboarding` |
| opencode | `/cosift-onboarding` |
| Codex CLI | `$cosift-onboarding` |

You type it, and that is the only way it starts. No Cosift tool call and no Cosift tool
response points you at the interview, and that is deliberate rather than an omission — the
reasoning is in [onboarding/docs/server-pointer-seam.md](onboarding/docs/server-pointer-seam.md).
If the harness was already running when you installed, restart it before looking for the
command.

`~/.local/bin/cosift-onboarding` is the local half. The interview runs it to check whether you
have done this already, and at the end it can record that you finished — or that you declined —
in `${XDG_CONFIG_HOME:-~/.config}/cosift/state.json`, or in `onboarding.json` beside it when
there is no `state.json`. It reads and writes that one file, makes no network call, and sends
nothing anywhere. If `~/.local/bin` is not on your `PATH` the interview still runs; it just
cannot read or record that flag. The installer's final summary warns you when `~/.local/bin` is
not on your `PATH`.

What the interview sends to Cosift is the strings you approved and nothing else — no file
contents, no file names. It does not read, list or search your files. The topic text you look
up or request is written into Cosift's shared demand ledger, which is not linked to your
account but is not private either, so keep client and project names out of it.
[onboarding/docs/ONBOARDING.md](onboarding/docs/ONBOARDING.md) is the full account of what the
interview does, what leaves your machine, and how to decline it once it is running.

### Removing it

`install.sh --uninstall` removes the interview together with the server entries. To do it by
hand, see [docs/UNINSTALL.md](docs/UNINSTALL.md#removing-the-onboarding-interview).

## Don't want to pipe to sh?

Reasonable. Download it, read it, then run it:

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/pilot-protocol/cosift-install/v1/install.sh
shasum -a 256 install.sh      # sha256sum on most Linux distributions
less install.sh
sh install.sh
```

About the digest: `v1` is a **movable** tag that we advance when we ship a fix, so its digest
changes over time. Compare what you computed against the digest published in the release
notes for the tag you are running. If you want a digest that never changes, pin the immutable
release tag instead of `v1`:

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/pilot-protocol/cosift-install/v1.0.0/install.sh
```

`raw.githubusercontent.com` caches for roughly five minutes, so a freshly moved `v1` may
serve the previous script for a few minutes after a release.

Running the downloaded file has one practical advantage beyond inspection: the interactive
prompts. The script always reads answers from `/dev/tty`, never from stdin, so the prompts
work under `curl | sh` as well — but if no `/dev/tty` is available (some CI runners, some
container invocations) it exits `6` and tells you to download and run it directly.

## Options

```
install.sh [OPTIONS]
  --dry-run          print the planned changes and write nothing to disk
  --uninstall        remove the cosift entry from every harness recorded in state, then remove state
  --harness=LIST     comma-separated subset of: claude,codex,opencode (skips the picker)
  --yes              accept all detected harnesses without prompting
  --onboarding       install the onboarding interview without asking
  --no-onboarding    do not install the onboarding interview
  --help             print usage to stdout and exit 0
  --version          print the version string to stdout and exit 0
```

An unrecognised option prints usage to stderr and exits `2`. So does passing `--onboarding` and
`--no-onboarding` together, or `--dry-run` with `--uninstall` — there is no uninstall preview.
`--yes` implies `--onboarding`; with neither flag you are asked.

`--dry-run` performs detection and prints, for each harness, exactly what would change. It
prints the interview plan too: the artifact path, and whether it is already byte-identical to
ours, an older copy of ours that would be replaced in place, a file we did not write that would
be backed up and then replaced, nothing there yet, or a symlink that would be refused. It
writes nothing at all — no backups, no state directory, no temp files in your home directory
— and it never runs the email flow. It may use a credential already on the machine to perform
one read-only check against the MCP endpoint, but it will not mint a new one.

`--uninstall` removes the onboarding interview as well as the server entries. It is documented
in [docs/UNINSTALL.md](docs/UNINSTALL.md).

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | success |
| `2` | usage error (unknown option, or flags that cannot be combined) |
| `3` | preflight failure — `curl` is missing, `$HOME` is not writable, or no supported harness was found |
| `4` | authentication failure — no usable credential could be obtained |
| `5` | harness write failure — a config was refused, a write failed, or the post-write re-read did not find our entry |
| `6` | interaction was required but `/dev/tty` could not be opened for reading |

The onboarding interview never changes the exit code. If it cannot be installed the installer
warns and carries on, and nothing that was already written is rolled back.

## Environment overrides

| Variable | Purpose |
| --- | --- |
| `COSIFT_AUTH_BASE` | override the auth service base URL used for the email code flow |
| `COSIFT_MCP_URL` | override the MCP server URL that gets written into the harness config |
| `COSIFT_EXTRA_HEADER` | one additional header in `Name: value` form, sent on every request the installer makes and written into the harness config next to `Authorization`; needed only when your Cosift deployment sits behind a gateway that requires a second header |
| `COSIFT_CODEX_SKILLS_DIR` | the skills root the Codex onboarding file is written under; defaults to `~/.agents/skills`. It has no effect on the MCP config, and `CODEX_HOME` has no effect on it |

Most people never set any of these. They exist so that a private or self-hosted Cosift
deployment can be pointed at without editing the script.

## Troubleshooting

### No code arrived

First, the honest part: **the installer cannot tell you whether an email was actually sent.**
`/auth/start` always returns the same 200 response with the same body, whether the address is
deliverable, unknown, malformed, or over quota. That is deliberate. If the response differed,
anyone could use it to test whether a given email address has a Cosift account — an account
enumeration oracle. We would rather be vague to you than be a lookup service for everyone
else. This is also why the installer says "if that address can be registered, a code is on
its way" instead of "we sent you an email".

So, in order:

1. Check the spam folder, and check that you typed the address correctly. A typo produces
   exactly the same response as a success.
2. Wait a minute. The call has a deliberate fixed delay, and delivery is not instant.
3. **There is a cap of three codes per address per hour.** If you have already asked three
   times in the last hour, further requests return the same 200 and send nothing. Wait out
   the hour rather than retrying.
4. Try a different address if you have one.

### "Invalid or expired code"

A wrong code and an expired code are **indistinguishable** — the server returns the same
`401 invalid or expired code` for a mistyped code, an expired code, a code from a request you
have since superseded by asking for a new one, and a request whose attempts are used up. If
you requested a second code, only the newest one can work; the older one now fails with that
same message.

The server stops accepting attempts after five, and the installer stops asking at that point.
Re-run the installer to start a fresh request (subject to the three-per-hour cap above).

### "Account not eligible" / HTTP 403

A `403` means the account is banned. This is a decision about the account, not about the
code, and getting a new token will not change it. The installer stops and exits `4`.

### "Temporarily unavailable" / HTTP 503

Infrastructure, not a verdict on your credential. Nothing is wrong with your email address or
your code. Wait and re-run. The MCP endpoint's `503` carries `Retry-After: 5`.

### Rate limited / HTTP 429

You are asking too often. The response carries no `Retry-After`, so there is no exact number
to give you; wait several minutes and try again.

### The final verification failed

The installer finishes by making one MCP `initialize` call with the credential it just wrote.
Those failures mean distinct things:

| Result | Meaning | What to do |
| --- | --- | --- |
| `401 invalid_token` | the server does not recognise the credential — typically it was revoked, or it was recovered from an old config and is no longer valid | re-run the installer; it will fall through to the email flow |
| `403` | the account is banned | a new token will not help |
| `421` | the MCP server does not accept the hostname the request arrived on (DNS-rebinding protection in the MCP SDK) | only reachable if you set `COSIFT_MCP_URL`; use the hostname your deployment actually serves |
| `503` | the backend is down | wait and re-run; `Retry-After: 5` |
| `405` | you made a `GET`; the MCP endpoint is `POST`-only | expected if you probed it by hand in a browser |

### "It only works in the directory where I ran the installer"

That cannot happen with Claude Code, because the installer always passes `--scope user`. The
default scope, which we do not use, is `local` — it writes the server under
`projects["<cwd>"].mcpServers` in `~/.claude.json` and would bind Cosift to whatever directory
you happened to be in.

To confirm:

```sh
claude mcp get cosift      # scope should read "user"
claude mcp list            # should list cosift from any directory
```

If you see a directory-scoped entry, it predates this installer or was added by hand. Remove
it with `claude mcp remove cosift` from that directory and re-run the installer.

### It says a harness is not installed

Detection is: the CLI on `PATH`, or (for Codex and opencode) the config file existing. If you
installed the harness via a shell function or an alias rather than something on `PATH`, the
installer will not see it. Run it again from a shell where `command -v claude` (or `codex`,
or `opencode`) prints a path.

## Revoking a token

Revoking is two separate actions and you usually want both:

1. **Stop your machine from using it** — run `install.sh --uninstall`, or follow
   [docs/UNINSTALL.md](docs/UNINSTALL.md) to remove the entry by hand. Remember the
   `.cosift-backup-*` files still contain the old token; delete them too.
2. **Stop the server from accepting it** — revocation is performed by the Cosift auth service
   against the account that owns the key. Request it from the email address you verified
   during install, quoting only the **key id** — the `ck_<keyid>_` prefix, for example
   `ck_1a2b3c_`. **Never send the full token.** A revoked token immediately returns
   `401 invalid_token` from the MCP endpoint.

Re-running the installer after a revocation gets you a new token through the email flow; the
recovery scan will not resurrect the revoked one, because the server is the arbiter of whether
a recovered token is usable.

## Uninstalling

```sh
curl -fsSL https://raw.githubusercontent.com/pilot-protocol/cosift-install/v1/install.sh | sh -s -- --uninstall
```

Full details, including manual removal for each harness: [docs/UNINSTALL.md](docs/UNINSTALL.md).

## Also in this repository

- [docs/UNINSTALL.md](docs/UNINSTALL.md) — automatic and manual removal, and how to restore a backup.
- [docs/HARNESSES.md](docs/HARNESSES.md) — the per-harness adapter reference: config paths, formats, and exact commands.
- [onboarding/docs/ONBOARDING.md](onboarding/docs/ONBOARDING.md) — the onboarding interview: what it asks, what it sends, what becomes public.
- [onboarding/docs/HARNESS-NOTES.md](onboarding/docs/HARNESS-NOTES.md) — where the interview file goes per harness, and what was and was not verified against a real one. It also covers a Hermes profile; `install.sh` does not configure Hermes.
- [onboarding/docs/server-pointer-seam.md](onboarding/docs/server-pointer-seam.md) — why nothing on the server side points at the interview.
- [onboarding/](onboarding/) — the source the interview is generated from. The installer carries the generated text inside itself and fetches nothing.
- [LICENSE](LICENSE) — MIT.

## License

MIT. See [LICENSE](LICENSE).
