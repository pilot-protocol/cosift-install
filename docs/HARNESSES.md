# Harness adapter reference

Internal reference for the three harness adapters in `install.sh`. Each adapter implements the
same five verbs — `detect`, `is_configured`, `add`, `remove`, `recover_token` — over a harness
that disagrees with the other two about header syntax, about the transport discriminator, and
about whether removal is even a supported operation.

Getting any of these details wrong does not produce an error. It produces a config that looks
right and silently does not work.

## The three adapters

| | **claude** (Claude Code) | **codex** (Codex CLI) | **opencode** (opencode.ai / sst) |
| --- | --- | --- | --- |
| **detect** | `claude` on `PATH` | `codex` on `PATH`, or `~/.codex/config.toml` exists | `opencode` on `PATH`, or the config file exists |
| **config path** | `~/.claude.json` | `~/.codex/config.toml`; `$CODEX_HOME` overrides `~/.codex` | `$XDG_CONFIG_HOME/opencode/opencode.json`, falling back to `~/.config/opencode/opencode.json`; `.jsonc` accepted for either. `~/.config` on macOS too, **not** `~/Library` |
| **format** | JSON (live state file, ~90 top-level keys) | TOML | JSONC — comments and trailing commas are legal |
| **key path** | `mcpServers.cosift` | `[mcp_servers.cosift]` | `mcp.cosift` |
| **transport discriminator** | `"type": "http"` | none — a `url` key implies HTTP | `"type": "remote"` (**not** `"http"`) |
| **header syntax** | `"Name: value"` — **colon** | TOML key/value under `[mcp_servers.cosift.http_headers]` | `Name=Value` — **equals** |
| **add** | `claude mcp add --transport http --scope user cosift "<MCP_URL>" --header "Authorization: Bearer <tok>"` | written by us, marker-delimited, appended to the file | `opencode mcp add cosift --url "<MCP_URL>" --header "Authorization=Bearer <tok>"` |
| **remove** | `claude mcp remove cosift --scope user` | delete the marker range | no subcommand exists — edit the file |
| **verify** | `claude mcp list`, `claude mcp get cosift` | `codex mcp list` if `codex` is on `PATH`, else grep our markers back | `opencode mcp list` |
| **recover_token** | read `~/.claude.json` | grep our marker block | grep the config file |

When `COSIFT_EXTRA_HEADER` is set, the extra header is written alongside `Authorization` in
each harness, in that harness's own syntax: a second `--header` argument for `claude` and
`opencode`, a second key under `[mcp_servers.cosift.http_headers]` for `codex`.

## claude

`--scope user` is mandatory. The CLI's default scope is `local`, which writes the server
under `projects["<cwd>"].mcpServers` and binds it to whatever directory the installer happened
to run in — under `curl | sh` that is wherever the user's shell was sitting. The same flag is
mandatory on remove, or the CLI looks in the wrong scope and reports the server as absent.

**Never write `~/.claude.json` with a shell read-modify-write.** It is Claude Code's live state
file: any running `claude` process rewrites the whole file from its own in-memory copy, so a
read-modify-write races it and loses either our entry or the user's session state. Adds and
removes go through the CLI. Reads are safe, which is why `recover_token` reads the file
directly.

The shape the CLI produces under `mcpServers`:

```json
"cosift": {
  "type": "http",
  "url": "...",
  "headers": { "Authorization": "Bearer ck_..." }
}
```

## codex

`codex mcp add` cannot set a literal header. It offers only `--bearer-token-env-var`, and
Codex does **not** expand `${VAR}` inside `http_headers` — it transmits the placeholder
literally, producing a config that parses fine and authenticates as the string `${VAR}`.

So the adapter writes the block itself, appended to the end of the file, delimited by markers
so that removal is exact:

```toml
# >>> cosift (managed by cosift-install — do not edit)
[mcp_servers.cosift]
url = "https://cosift-mcp-udik5erlkq-uw.a.run.app/v1/mcp"
[mcp_servers.cosift.http_headers]
Authorization = "Bearer ck_..."
# <<< cosift
```

Remove is an `awk`/`sed` range delete of exactly the marker range, leaving the rest of the
file byte-identical.

**Refusal case:** if the file already contains an `[mcp_servers.cosift]` table that is *not*
inside our markers, the adapter refuses and the installer exits `5`. Appending would create a
duplicate TOML table, which is a parse error — that breaks every MCP server the user has, not
just ours. Refusing to touch a config we did not write is always the correct call here.

## opencode

Always add through the CLI. Their writer is `jsonc-parser` based and preserves the user's
comments and formatting; our own writer would not.

Removal is the hard part, because **there is no `opencode mcp remove`**. The adapter:

1. Backs the file up first.
2. Edits it with a brace-matching routine that is **string-aware and comment-aware**: a `{` or
   `}` inside a `"quoted string"` (respecting `\` escapes), inside a `//` line comment, or
   inside a `/* block comment */` must not affect the brace depth. It deletes the `"cosift"`
   key and its value object from the `"mcp"` object, plus the now-dangling comma — leading or
   trailing, whichever applies.
3. Validates: run `opencode mcp list` (when `opencode` is on `PATH`), require exit 0, and
   require that `cosift` is no longer listed.
4. On any validation failure whatsoever, **restores the backup**, prints precise manual
   removal instructions, and exits non-zero.

Do not reach for `jq` or Python's `json` module on this file. Both reject real opencode
configs — the comments and trailing commas that JSONC permits are parse errors to them — and
even where they succeed they would rewrite the file and destroy the user's comments.

## Token format and recovery

```
ck_<keyid>_<secret>
```

`keyid` is lowercase alphanumeric. `secret` is RFC 4648 uppercase base32 of 24 bytes with no
padding — exactly 39 characters from `[A-Z2-7]`. The recovery regex is therefore:

```
ck_[0-9a-z]+_[A-Z2-7]{39}
```

Recovery scans every known config path of all three harnesses, then validates each candidate
with a real MCP `initialize` call; the first that returns HTTP 200 is reused and the email
flow is skipped entirely. **The endpoint, not the regex, is the arbiter** — which is what makes
a deliberately loose extraction safe. A false positive costs one request and gets rejected.

Use `grep -E`. `grep -P` is not portable (macOS `grep` has no `-P`).

## Not yet supported

### Hermes Agent (Nous Research)

Researched, deliberately deferred. Everything below is what was established at the time of
research, recorded so that a future session can implement the adapter in one sitting rather
than re-deriving it. Re-verify before writing code.

| | |
| --- | --- |
| CLI | `hermes` |
| config path | `~/.hermes/config.yaml` |
| format | YAML |
| key path | `mcp_servers.<name>` |
| transport discriminator | none — a `url` key implies HTTP |
| headers | nested `headers:` map |
| variable expansion | `${VAR}` **is** expanded inside headers (unlike Codex) |

**Why it was deferred — the blocker:** Hermes configuration is **per-profile**. Profiles live
at `~/.hermes/profiles/<name>/config.yaml`, `~/.hermes/active_profile` selects the active one,
and `$HERMES_HOME` overrides the root. A user on a named profile reads that profile's config,
not `~/.hermes/config.yaml` — so an adapter that writes the default `config.yaml` would report
success, write a valid file, and do absolutely nothing for that user. A correct adapter has to
resolve `$HERMES_HOME`, read `active_profile`, and write into the resolved profile directory,
including the case where the profile directory exists but has no `config.yaml` yet.

Secondary blocker: we could not confirm a non-interactive `--header` flag on `hermes mcp add`.
If there is none, the adapter has to write YAML itself — and hand-writing YAML into someone
else's config is materially worse than the TOML case, because YAML has no marker-safe append
(indentation is structure, so an appended block must be merged into an existing
`mcp_servers:` mapping rather than concatenated).

Possible alternative path, **unverified**: `hermes import-agent claude-code` appears to import
an existing Claude Code configuration. If it imports MCP server entries including headers, the
adapter could become "configure Claude Code first, then invoke the importer", which would side-
step both blockers. Worth ten minutes of checking before writing a YAML writer.

Until the profile resolution is settled, Hermes stays out. A harness adapter that silently
writes to the wrong file is worse than no adapter at all.

### Everything else

The installer says nothing about harnesses it does not support — no "detected but unsupported"
messaging, no suggestions. Detecting other software on a user's machine and reporting on it is
not something an installer should be doing.
