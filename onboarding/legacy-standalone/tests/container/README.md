# Tier B — install mechanics in a throwaway HOME

Proves that `install-onboarding.sh` puts exactly one file in exactly the right
place, on the real production paths, inside a disposable container HOME. No
agent authentication, no API key, and no contact with the Cosift service: the
test container runs with `--network none`.

## Build and run

```sh
./run.sh                 # build the image, then run every assertion
./run.sh --no-build      # reuse the existing image
./run.sh --no-cache      # rebuild from scratch, re-resolving the npm CLIs
./run.sh --self-test     # run against fixtures/mock instead of onboarding/
./run.sh --shell         # interactive shell with the same mounts
```

Exit codes: `0` all observed assertions passed, `1` at least one failed,
`2` nothing was proven (no usable installer found — the run prints `SKIP-ALL`).

The image is `node:22-bookworm-slim` with a non-root user `cosift` and
`HOME=/home/cosift`. `onboarding/` is mounted read-only at `/opt/onboarding`;
the assertions live in `fixtures/` and are mounted at `/opt/fixtures`, so
editing them does not require a rebuild.

Only the build talks to the network, to `npm install` the harness CLIs. If any
CLI will not install, the build still succeeds: `fixtures/install-clis.sh`
writes a named stub onto PATH and records it in `/opt/cosift-test/cli-report.tsv`.
`run.sh` reads that file and prints a banner naming every stubbed CLI, and every
assertion needing a stubbed CLI reports SKIP rather than PASS.

## What it proves

Per harness (claude, codex, opencode, and hermes, which the installer also
accepts):

- the install writes exactly the contract path, file mode 0644, every ancestor
  directory 0755, and **nothing else under HOME changes** — checked by diffing a
  full `(mode, sha256, path)` manifest of HOME before and after;
- the frontmatter parses, and its key set is inside the per-harness allowed set;
  for codex the set is exactly `name` and `description`;
- a second install is byte-identical and creates no backup;
- a pre-existing foreign file at our path is refused without `--force`, and with
  `--force` the foreign bytes survive in a backup file;
- `--uninstall` removes our file and our own now-empty directory while a
  pre-seeded sibling skill/command survives and the shared parent directory
  (`~/.claude/skills`, `~/.agents/skills`, `.../opencode/commands`) still exists;
- `--dry-run` writes nothing, on a clean HOME and on an already-installed HOME,
  proven by the whole-HOME sha256 manifest.

Plus:

- codex is not also installed into the legacy `~/.codex/skills`, and
  `--codex-skills-dir` redirects the install while leaving `~/.agents/skills`
  untouched;
- the opencode duplicate-directory guard fires when a rival
  `~/.config/opencode/command/cosift-onboarding.md` (singular) is pre-seeded;
- **the headline assertion, the skillinject inversion**: `~/.claude/CLAUDE.md`,
  `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md` and `~/.hermes/SOUL.md`
  (plus `~/AGENTS.md` and `~/AGENTS.override.md`) are pre-seeded with known
  content and are byte-identical after installing every harness **and** after
  uninstalling every harness.

Discovery, with no auth:

- **opencode: real.** `opencode serve --pure` is started inside the container and
  `GET /command` is fetched over loopback; the assertion is that
  `cosift-onboarding` appears with `source: command` and the exact description
  from the installed frontmatter.
- **codex: real.** `codex debug prompt-input` renders the model-visible prompt
  offline; the assertion is that the `<skills_instructions>` block lists
  `cosift-onboarding` with its installed description, resolved from the
  `~/.agents/skills` root.
- **claude: UNPROVEN.** Claude Code 2.1.273 exposes no no-auth listing of
  installed skills. `claude doctor` and `claude plugin list` are both probed and
  neither mentions the artifact, so the run prints
  `DISCOVERY: UNPROVEN (claude)` and counts a SKIP. It is never downgraded into
  a weaker assertion that would look green.

Two `NOTE` lines report that opencode's external-skill scan can see the claude
and codex artifacts. That is a second reader agreeing about the path and the
frontmatter; it is informational and deliberately not counted as native claude
or codex discovery.

## What it deliberately does not prove

- **Nothing about the interview itself.** No model is ever invoked. The body
  text, the consent gate, the 3-request cap and the MCP tool handling are Tier A
  and Tier C concerns.
- **No Cosift service behaviour.** The container has no network at all, so no
  MCP tool is ever called and no topic ever reaches the demand ledger.
- **Not that the harnesses execute the artifact.** opencode and codex are proven
  to *list* it; nobody is proven to *run* it. Running requires auth.
- **Nothing about claude discovery** (see above), and nothing about Hermes as a
  harness: Hermes ships UNVERIFIED and no Hermes binary exists to test against.
  Only the hermes install *paths* are exercised.
- **Not the host.** Everything happens in a throwaway container HOME; the
  suite never writes to the real `~/.claude` or `~/.config`.
- The `--force` backup is proven to contain the displaced bytes; the backup
  *filename* format is not asserted.
- Idempotency is content-based. An installer that rewrites identical bytes with
  a new mtime still passes; the isolation assertion is what catches stray files.

## fixtures/mock

`fixtures/mock/` is a reference implementation of the install contract used by
`run.sh --self-test`. It is **not** the shipped installer and is never installed
anywhere. It exists so the assertions themselves can be checked: they pass
against a correct installer, and a deliberately broken variant was used during
development to confirm each assertion actually fails when violated (wrong file
mode, stray files, overwriting a foreign file without `--force`, silently
installing next to the opencode rival, an illegal extra codex frontmatter key,
`--dry-run` that writes, uninstall that deletes the shared parent, and an
installer that appends to `CLAUDE.md` — 24 failures, all caught).

## What tier A pins instead

Two install behaviours are deliberately **not** asserted here: `--uninstall` backing up a
file that is not byte-identical to ours before removing it, and the installer honouring
`COSIFT_CODEX_SKILLS_DIR`. These assertions are written against an unknown installer, and
`fixtures/mock` implements neither, so adding them would make `--self-test` fail for the wrong
reason. `tests/shell/cases/50-install.sh` covers both against the real script.

## Last run

2026-09-16, against `onboarding/bin/install-onboarding.sh`, re-run with `--no-build` after the
whole-tree review pass: **53 pass, 0 fail, 1 skip** (`discovery.claude`, reported UNPROVEN).
That run reused the image built earlier the same day, so it did not re-exercise the build
path. The earlier same-day run with the build included was also 53 pass, 0 fail, 1 skip, and
`--self-test` against `fixtures/mock` on the same day: 53 pass, 0 fail, 1 skip.

Nothing was stubbed. All three CLIs installed for real:

| CLI      | npm package             | version        |
| -------- | ----------------------- | -------------- |
| claude   | @anthropic-ai/claude-code | 2.1.273      |
| codex    | @openai/codex           | codex-cli 0.154.0 |
| opencode | opencode-ai             | 1.18.31        |
