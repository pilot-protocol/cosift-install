# The Cosift onboarding interview

`cosift-onboarding` is one file that your agent reads when you ask for it. It runs a short
interview that turns what you say you are interested in into two things:

1. **Followed topics.** These are stored on your account. Unlike a lookup or a request, a
   follow is not written into Cosift's shared demand ledger. Following a topic is not a
   request for coverage.
2. **At most three coverage requests.** A request records demand. It is not a promise that an
   article will be written.

The interview uses only what is in your conversation. It never reads, lists or searches your
files. On every harness that rule is the first hard rule in the body of the file: interests
come from the conversation and from nowhere else.

On Claude Code, and only there, part of that is also enforced by the harness. The skill's
frontmatter carries:

```yaml
disallowed-tools: Read, Glob, Grep, Write, Edit, NotebookEdit, WebFetch, WebSearch, Task
```

which is the list of tools the agent is not given while the skill runs. Read it as exactly
what it says, and no more:

- `Bash` is deliberately **not** on that list, because the interview runs one local command,
  `cosift-onboarding status`. A shell therefore remains available to the model, so on Claude
  Code the "no files, no network" promise is a hard rule in the body backed by a partial
  mechanical fence, not by a complete one.
- Codex and opencode have no equivalent frontmatter key at all. On both the rule is
  instruction-only.

That is the honest shape of it. The mechanical guarantees this artifact does make in full are
about the installer and the file itself: one static file per harness, no timer, no runtime
fetch, no network call in the interview or in the `cosift-onboarding` command, and never a
write to an always-loaded instruction file.

## What runs, in order

1. **Self-check.** The agent checks that the four Cosift tools are present in the session and
   runs `cosift-onboarding status` once, which reads a local file and writes nothing.
2. **Questions.** Two to four short questions about what you work on and what you want to keep
   up with. If the conversation already shows what you care about, the agent proposes from it
   and says which part of the conversation it inferred that from.
3. **Consent gate.** Before any Cosift call at all, the agent shows a fixed disclosure block
   and asks yes or no. `cosift_search` is the only tool permitted to run before this point,
   and in the normal flow nothing runs before it, because the first search belongs to step 5.
4. **Broad interests become followed topics**, in exactly one `cosift_topics("add", ...)`
   call, using strings you approved character for character.
5. **Specific gaps become at most three requests.** Each candidate is first rewritten with
   you into a short lowercase noun phrase, then searched, then looked up only if the search
   did not settle it. The rewrite comes first on purpose: the lookup is what writes the
   phrasing into the shared ledger, so the short form is what gets recorded.
6. **Verify and report.** One `cosift_topics("list")` call, reconciled honestly against what
   was intended. Anything the agent cannot confirm is reported as unconfirmed.
7. **Persist.** The agent offers to run `cosift-onboarding complete`, which records locally
   that the interview finished, so it is not offered again. It sets three keys in that file,
   `onboarded`, `onboarded_at` and `onboarding_version`, leaves one timestamped backup of the
   file it replaced, and sends nothing anywhere.

Hard caps for one interview: at most 6 `cosift_lookup` calls and at most 3 `cosift_request`
calls. `cosift_topics` is one `add` and one `list`, plus one further `add` or `remove` only if
you ask for it. The three-request cap is ours, applied inside the interview. It is not a
server limit, and a later run can add more.

## What leaves your machine, and what becomes public

Only the strings you approve, sent to the Cosift MCP server. No file contents, no file names,
no machine information.

**The link between your account and a topic is private. The words of the topic are not.**

- Every non-blank `cosift_lookup` and every `cosift_request` writes into Cosift's shared
  demand ledger, a global record keyed by topic. That record stores the literal text of the
  topic, a counter and a timestamp. It is not linked to your account, but it is not private.
- `cosift_topics` and the account-to-topic link stay inside your account. A follow is never
  written into the shared ledger.
- The one-line `why` you give with a request is stored on your account next to the topic. It
  is not written into the shared ledger, and no tool in this interview can delete it
  afterwards. Keep client and project names out of it for the same reason you keep them out
  of the topic.
- `cosift_search` reads the corpus and writes nothing to the ledger, but the query text
  itself still reaches Cosift's servers.
- If a topic is later covered, the resulting article and its title are public.

Cosift does keep usage counters on your account: how many tool calls you made today, broken
down per tool, and how many bytes it sent back. That is how the cap of 1000 calls a day is
enforced. It is not "no telemetry", and calling it that would be false.

So do not put client names, internal project names or unreleased products into a topic.
Plain public words work best. The agent shows you every exact string before it is sent, and
that includes the strings it sends to `cosift_lookup`, not only the ones it requests.

The two local commands, `cosift-onboarding status` and `cosift-onboarding complete`, read and
write a single file under `${XDG_CONFIG_HOME:-~/.config}/cosift/` and make no network call.

## What the corpus actually holds

Cosift indexes developer documentation, technology and consumer journalism, and academic
literature. Law and regulation, finance, and standards are close to absent today. That is a
statement about the corpus, not a judgement about your subjects: if you work in one of those
three, expect the interview to record demand and to find very little to show you now.

## Coverage today

Cosift's article layer is not switched on, so no lookup can return an article right now.
Both `thin` and `none` mean the same thing today: there is no article on this topic. The only
difference is the size of the retry window the response quotes. The agent is required to say
that plainly and to echo the number the response actually returned rather than any number
written down here.

That number is a fixed server setting, the same for every topic and every account. It is not
an estimate for your topic and it is not a schedule. Today nothing converts a recorded
request into an article, because the article layer is off, so the same answer comes back
after the window as before it. What a request buys you now is a counter in the demand ledger.

## How to decline

One word. "No" at the consent gate, or at any point before it, ends the interview. Nothing is
written and nothing is sent. The agent acknowledges it in one sentence and stops. It then
mentions, as a statement and not as a second question, that
`cosift-onboarding complete --declined` records the decline so the interview is not offered
again; it runs that only if you ask it to. It will not ask twice and it will not argue.

## How to re-run it

Type the invocation again:

| harness | invocation |
| --- | --- |
| Claude Code | `/cosift-onboarding` |
| opencode | `/cosift-onboarding` |
| Codex | `$cosift-onboarding` |

If you already completed it, the agent says so and asks whether to run it again. If you
declined it before, the agent says that instead, asks once, and takes no for an answer. It
reads which of the two applies from the word `cosift-onboarding status` prints, not from the
exit code, because both share exit 1. Re-running `install.sh` does not clear that record.

Following more topics or making more requests later is fine: requests are idempotent per
account, so asking twice for the same topic costs nothing.

## Which single file was installed

One file per harness:

| harness | the one file |
| --- | --- |
| Claude Code | `~/.claude/skills/cosift-onboarding/SKILL.md` |
| Codex | `${COSIFT_CODEX_SKILLS_DIR:-~/.agents/skills}/cosift-onboarding/SKILL.md` |
| opencode | `${XDG_CONFIG_HOME:-~/.config}/opencode/commands/cosift-onboarding.md` |

Beside them the installer writes one shared helper, `~/.local/bin/cosift-onboarding`, mode
0755. That is the `status` and `complete` command the interview runs. If `~/.local/bin` is not
on your PATH the installer says so in its closing summary: the interview still runs, but it
cannot record that you finished it.

The file is 0644. The `cosift-onboarding` directory it sits in, and the shared `skills/` or
`commands/` directory above that, are 0755. Anything the installer has to create further up —
`~/.claude`, `~/.agents`, `~/.local`, `~/.config/opencode` — is created under `umask 077` and
comes out 0700.

If something else is already sitting at our path, the installer copies it to
`<path>.cosift-backup-<UTC>` before replacing it, and `--uninstall` does the same before
removing it. A file we shipped in an earlier release is recognised as ours instead: it is
replaced in place, with no backup. Backups are never deleted, including by `--uninstall`. On
opencode they land in the shared `commands/` directory, so that is where to look for a stray
`cosift-onboarding.md.cosift-backup-...` later.

It never writes to an always-loaded instruction file. The installer holds no list of forbidden
names; the guarantee comes from the shape of what it writes. The three paths above are fixed
in the script and always end in `cosift-onboarding/SKILL.md` or `cosift-onboarding.md` — the
directory can be moved by the two environment variables shown, but the name at the end of it is
never read from a config file and never taken from a command-line argument. A path that turns
out to be a symlink is refused and left alone, so a link aimed at one of those files is never
followed. The file is written under a temporary name beside its destination and renamed into
place, which replaces the directory entry rather than writing through a hard link. Cases C43
and C48 in `tests/run.sh` pin the outcome: `CLAUDE.md`, `AGENTS.md`, `AGENTS.override.md` and
`SOUL.md` are byte-identical after installing and after uninstalling every harness, and stay
that way when one of them is planted at our path as a symlink and another as a hard link.

There is no timer, no background process and no runtime fetch. The file is static and
versioned, and its first line after the frontmatter names the version it was generated from.

`install.sh` does not configure Hermes. A Hermes profile and a generated Hermes artifact are
kept in the source tree as a record of the contract, for a release that adds it.

## How to remove it

```sh
install.sh --uninstall
```

That removes the interview file wherever it finds one, the `cosift-onboarding` directory it
created if that directory is now empty, the `~/.local/bin/cosift-onboarding` command and the
installer's state files — together with the Cosift entry in each harness config. There is no
command that removes only the interview, and `--uninstall --dry-run` is a usage error, so
there is no way to preview a removal.

It does not take the state file's word for where the interview is: it also looks at the three
paths above and removes whatever it recognises as ours, so a file left behind by an earlier run
is still found and a second attempt still works. A file it cannot remove is named on stderr as
a warning, not a failure, so the run can still exit 0 while naming something you have to delete
yourself.

Deleting the file by hand does almost the same thing: on Claude Code and Codex it leaves the
now-empty `cosift-onboarding/` directory behind, which is one `rmdir` to clear. On opencode
there is no such directory, because the file sits directly in `commands/`. Either way the
shared `skills/` and `commands/` directories are never removed.

### Undoing what the interview recorded on the server

This part is asymmetric, and the difference matters:

- **A topic you only followed.** `cosift_topics("remove", ["first topic"])` deletes the
  account record. It is gone from `cosift_topics("list")`.
- **A topic you requested.** The same call reports success and clears the follow markers, but
  the account record survives, because Cosift keeps the request time so a later request
  cannot double-count the demand. The topic text, the time you asked and your `why` line stay
  on your account, and the topic keeps appearing in `cosift_topics("list")` with
  `requested: true`. There is no tool on this surface that deletes it. Do not read
  `remove` as undoing a request.
- **Either way**, the topic text already written into the shared demand ledger stays there.

To forget the local flag, delete `${XDG_CONFIG_HOME:-~/.config}/cosift/onboarding.json`, or,
if the Cosift installer wrote one, set `"onboarded": false` in
`${XDG_CONFIG_HOME:-~/.config}/cosift/state.json`. `complete` also left one
`state.json.cosift-backup-<UTC>` beside it; that file is yours to delete.
