# INTEGRATION.md — graft contract for the T3 session

Addressed to whoever owns `cosift-install`. Mechanical, no discussion.

## 1. Copy

```sh
cp -r onboarding/ ../cosift-install/
```

`onboarding/` is self-contained: body, profiles, generator, the committed `generated/` tree
with `MANIFEST.json`, the two scripts, the docs and the tests. Nothing outside it is needed.
Keep the executable bit on `onboarding/bin/cosift-onboarding` and
`onboarding/bin/install-onboarding.sh` (both 0755).

Do not hand-edit anything under `onboarding/generated/`. It is built by
`python3 onboarding/tools/generate.py`, and `--check` fails on drift.

## 2. Install one harness at a time

```sh
onboarding/bin/install-onboarding.sh --harness <claude|codex|opencode|hermes> [--dry-run] [--uninstall]
```

Other flags: `--force` (replace a foreign file after backing it up; also overrides the
opencode collision guard), `--codex-skills-dir DIR`, `--prefix DIR` (test only),
`--manifest PATH`, `--help`.

Exit codes: `0` the action succeeded or `--dry-run` produced a plan, `1` refused or failed,
`2` usage error. Stdout is one line per action, the verb first and the absolute path last.
The complete set:

| line | when |
| --- | --- |
| `installed <path>` | install wrote the file |
| `unchanged <path>` | install found our exact bytes already there |
| `backed up <path> -> <backup>` | `--force` install, or `--uninstall` of a file that is not ours |
| `removed <path>` | `--uninstall` removed the file |
| `removed directory <dir>` | `--uninstall` removed our own now-empty directory |
| `not installed <path>` | `--uninstall` found nothing there |
| `left in place <path>` | `--uninstall` can still see a backup file it will not delete |
| `would install <path>` / `would replace <path>` | `--dry-run` install, followed by a unified diff |
| `would refuse: <path> exists and differs...` | `--dry-run` install over a foreign file with no `--force` |
| `would back up <path> -> <path>.cosift-backup-<UTC>` | `--dry-run --uninstall` of a file that is not ours |
| `would remove <path>` | `--dry-run --uninstall` |
| `would remove directory <dir>` | `--dry-run --uninstall`, when the directory would end up empty |

Refusals go to stderr. Do not parse the diff body; it is only present after
`would install` / `would replace`.

`--dry-run` never creates a directory, a backup or a file, and exits 0 whenever it can work
out a plan, including plans it reports as refusals.

Backups are never deleted by this script. `--force` and the non-byte-identical `--uninstall`
path both leave `<path>.cosift-backup-<UTC>` behind on purpose. If your uninstall wants a
clean directory it has to remove those itself, and it should tell the user it is doing so.

### Record the installed file

For your own uninstall, take the path from the manifest rather than by parsing prose:

```sh
onboarding/bin/cosift-onboarding paths --json
# {"source":"manifest","manifest_path":"...","paths":{"claude":"...","codex":"...","opencode":"...","hermes":"..."}}
```

`paths` honours `XDG_CONFIG_HOME`, `HERMES_HOME` and `COSIFT_CODEX_SKILLS_DIR`, and so does
the installer, so exporting `COSIFT_CODEX_SKILLS_DIR` once keeps the two in agreement. What
`paths` cannot see is the installer's per-invocation `--codex-skills-dir` flag, which wins
over the environment variable. Use the environment variable, not the flag, when anything else
has to know where the file went.

Your uninstall should call `install-onboarding.sh --uninstall --harness <h>` rather than
deleting paths itself. It removes our file and then our own `cosift-onboarding` directory
only if that directory is empty; it never removes `~/.claude/skills`, `~/.agents/skills`,
`~/.config/opencode/commands` or `~/.hermes/skills`.

## 3. After a successful install

```sh
onboarding/bin/cosift-onboarding status
```

| exit | word | meaning | what install.sh does |
| --- | --- | --- | --- |
| 0 | `pending` | onboarding is due | offer to launch the interview |
| 1 | `done` / `declined` | already onboarded or declined | say nothing, do not offer |
| 2 | `unknown` | no state file | offer, and say completion is recorded in the interview's own file |
| 3 | `malformed` | state file unparseable | do not offer, report the path |
| 4 | | usage error | treat as a bug |

On exit 0, offer to launch the user's agent and have them type the invocation:

| harness | invocation |
| --- | --- |
| claude | `/cosift-onboarding` |
| opencode | `/cosift-onboarding` |
| hermes | `/cosift-onboarding` |
| codex | `$cosift-onboarding` |

If more than one harness was configured, ask which one to launch, or tell the user to run it
in whichever agent they prefer when they are ready. Do not launch anything without an answer,
and do not launch more than one.

## 4. The state.json / onboarding.json asymmetry

`${XDG_CONFIG_HOME:-$HOME/.config}/cosift/state.json` is yours. Shape
`{version, account_uid, harnesses_configured[], onboarded:false, installed_at}`.

- When `state.json` exists, `cosift-onboarding complete` read-modify-writes it in place. It
  sets only `onboarded`, `onboarded_at` and `onboarding_version`, preserves every other key
  including ones it does not understand, backs the file up first, and writes 0600. The backup
  is `state.json.cosift-backup-<UTC>`, it is named in the `recorded:` line on stdout, and any
  earlier backup of that file is dropped so at most one is ever left in your directory. The
  0600 is deliberate: the file carries `account_uid`, so the mode is not inherited from
  whatever you created it with.
- When `state.json` does not exist, it writes
  `${XDG_CONFIG_HOME:-$HOME/.config}/cosift/onboarding.json` instead and **never fabricates
  `state.json`**. `status` reads either and prefers `state.json`.

The reason is your uninstall. A fabricated `state.json` would have to invent
`harnesses_configured`, and your uninstall drives off that list: an invented list would make
it either skip a harness it should clean up or touch a config file it never wrote. A missing
`state.json` is a fact worth preserving, so the interview keeps its own flag beside it.

## 5. P1 for your session

Your README (or its draft) tells the user that **the first tool call will offer the
onboarding interview**. That sentence describes a server-side offer, which was explicitly
ruled out for launch: no MCP tool response contains a pointer to the interview, and no prompt
injection of any kind ships. The trigger is local and user-driven only: your installer offers
it at the end of an install, and the user types `/cosift-onboarding` in their agent.

Reword it to say that install.sh offers to run the interview, and that the user can run it
later by typing the invocation in their agent. The deferred server-side variant, and the rule
that any future pointer must be a fixed constant pinned by a test asserting it contains no
verb and no sentence, is written up in `onboarding/docs/server-pointer-seam.md`. As of
2026-09-16 the sentence was not yet in the checked-out `README.md`; if it is in your draft,
this applies to the draft.

## 6. Open mechanics, decide before you wire it up

1. **How does `onboarding/` reach the user's machine?** `install.sh` is designed for
   `curl | sh`, where it is the only file present, but `install-onboarding.sh` needs
   `onboarding/generated/` next to it. Decide between shipping a tarball or repo checkout
   path, or having `install.sh` skip the onboarding install when `onboarding/` is not beside
   it and print the manual one-liner instead. The safe launch default is to skip and print.
2. **Is `cosift-onboarding` on the user's PATH?** Nothing currently puts it there. The
   interview calls `cosift-onboarding status` in phase 0 and `cosift-onboarding complete` in
   phase 6, and handles a missing command by continuing silently, so the interview still
   works, but completion is not recorded and it can be offered again. If you want it
   recorded, install the script somewhere already on PATH, disclose that file in your output
   and record it for your uninstall. Do not modify the user's shell configuration.
