# Cosift onboarding

Onboarding is one step. Your agent shows you a short list of subjects, you approve it, and those
become the topics your Cosift account follows — plus, for the few specific ones worth a written
piece, a record that someone wants one. A recorded request is demand, not a promise that an
article gets written.

The full audit trail — every file, every tool call, every line added to your Claude Code
settings — is in [docs/WHAT-HAPPENS.md](../../docs/WHAT-HAPPENS.md). This document is the short
version: what the step is like, and what it means.

## How it starts

| harness | starts by itself | you can also type |
| --- | --- | --- |
| Claude Code | yes, from a `SessionStart` hook | `/cosift-onboarding` |
| opencode | no | `/cosift-onboarding` |
| Codex | no | `$cosift-onboarding` |

Auto-start is Claude Code only. Codex plugins install from a marketplace and opencode plugins
are npm modules, so neither can start anything on its own. Codex has not been tested against a
real Codex build at all — see [HARNESS-NOTES.md](HARNESS-NOTES.md).

On Claude Code, if you open the session and ask for nothing, the interview runs. If you opened
it to get something done, the agent does your work and tells you in one line at the end that
Cosift is not set up yet. Never both in the same turn, and never twice in one session.

Nothing on Cosift's side offers you the interview. The trigger is a hook on your machine reading
a file on your machine, and the server is never told whether you have onboarded; the reasoning
is in [server-pointer-seam.md](server-pointer-seam.md).

## What runs, in order

1. **The digest.** The agent runs `cosift-onboarding digest`, a local command that prints the
   titles your AI tools generated for your own recent sessions. It reads only those titles,
   never the text of what you typed, and never anything else on disk.
2. **Generalisation.** Each title becomes an ordinary public subject. This is the part that
   matters — see below.
3. **One list.** You get one short list in two groups: subjects to follow, and at most three
   worth asking Cosift to write about. Edit any line, cut any line, add your own. The agent
   tells you, in the same message, that it drafted this from a local summary of your recent
   session titles, that the summary stays on this machine, and that Cosift receives only the
   lines you approve.
4. **One yes.** On approval the agent submits the list and says in one line what landed. Every
   string is one you saw in that list; nothing else is sent.
5. **Done.** `cosift-onboarding complete` records locally that this is finished, so it never
   starts by itself again. That command writes one local file and sends nothing anywhere.

If there is no session history to read — a new machine, a fresh install — the digest prints
nothing and the agent asks you directly instead.

## The rule about names

Session titles carry client names, product names, repository names and incident codenames. The
subject is the interesting part, not the name: a session titled "Acme billing migration" is
proposed as `multi-tenant billing`, not as anything with Acme in it.

So nothing identifiable is put in front of you as a suggestion, and nothing identifiable is
sent. If you add such a name to the list yourself, the agent says once that those exact words
become public, and offers the ordinary form instead. The reason is in
[what becomes public](#what-leaves-your-machine-and-what-becomes-public) below: the topic text
goes into a shared ledger with no delete path.

## What it reads, and what it does not

The digest is the only thing the interview reads. You can run it yourself and see exactly what
the agent saw:

```sh
cosift-onboarding digest
```

One session title per line, newest first, from Claude Code, opencode and — best effort,
unverified — Codex. A title that holds a path, a web address or an email address is dropped
rather than cleaned, because those carry the names above. Nothing is written and no network
connection is made.

On Claude Code, part of this is enforced by the harness rather than by instruction. The skill's
frontmatter carries:

```yaml
disallowed-tools: Read, Glob, Grep, Write, Edit, NotebookEdit, WebFetch, WebSearch, Task
```

which is the list of tools the agent does not have while the interview runs. Read it as exactly
what it says: `Bash` is deliberately **not** on that list, because the digest and the completion
record are local commands, so a shell remains available to the model. The fence is partial, and
Codex and opencode have no equivalent frontmatter key at all — on those the rule is
instruction-only.

## What leaves your machine, and what becomes public

Only the strings you approve, sent to the Cosift MCP server. No file contents, no file names, no
machine information, and no part of the digest that you did not approve.

**The link between your account and a topic is private. The words of the topic are not.**

- A topic you look up or request is written into Cosift's shared demand ledger: a global record
  of what people are asking for, holding the literal text, a counter and a timestamp. It is not
  linked to your account, but it is not private, and **there is no delete path** — no tool here
  removes an entry from it.
- Topics you only follow stay on your account. A follow is never written into the ledger.
- The one-line reason you give with a request is stored on your account beside the topic. It is
  not written into the ledger, and no tool here can delete it afterwards.
- A search query reaches Cosift's servers even though search writes nothing to the ledger.
- If a topic is later covered, the resulting article and its title are public.

So: plain public words, no client names, no internal project names, no unreleased products.

None of the local commands makes a network call. `digest` reads the session stores named above
and writes nothing; `status` and `complete` read and write one file under
`${XDG_CONFIG_HOME:-~/.config}/cosift/`.

## What the corpus holds

Cosift indexes developer documentation, technology and consumer journalism, and academic
literature. Law and regulation, finance, and standards are close to absent. That is a statement
about the corpus, not a judgement about your subjects: if you work in one of those three, expect
the step to record demand and to find little to show you.

## Saying no

One word, at any point. Nothing is sent to Cosift. The agent acknowledges it in one sentence,
runs `cosift-onboarding complete --declined` so that this does not come up again — a local
record, in one local file — and stops. It will not ask twice and it will not argue.

## Doing it again

Type the invocation from the table above. If you completed it before, the agent says so and asks
whether to run it again; if you declined before, it says that instead, asks once, and takes no
for an answer. Re-running the installer does not clear that record.

Following more topics or requesting more later is fine: requests are idempotent per account, so
asking twice for the same topic costs nothing.

## What was installed

One file per harness, plus one shared command:

| harness | the one file |
| --- | --- |
| Claude Code | `~/.claude/skills/cosift-onboarding/SKILL.md` |
| Codex | `${COSIFT_CODEX_SKILLS_DIR:-~/.agents/skills}/cosift-onboarding/SKILL.md` |
| opencode | `${XDG_CONFIG_HOME:-~/.config}/opencode/commands/cosift-onboarding.md` |
| all three | `~/.local/bin/cosift-onboarding`, mode 0755 |

The files are 0644, hold no credential, and are static text: no timer, no background process,
nothing fetched while they run. The installer never writes to an always-loaded instruction file;
the paths above are fixed in the script, a symlink at one of them is refused and left alone, and
each file is written under a temporary name beside its destination and renamed into place, so it
never writes through a link.

On Claude Code the installer also adds one `SessionStart` hook and five permission grants to
`~/.claude/settings.json` — the hook is what makes this start by itself, and the grants are what
stop the agent asking you to approve each call. Both are listed line by line, with what each
allows, in [docs/WHAT-HAPPENS.md](../../docs/WHAT-HAPPENS.md#3-the-change-to-claudesettingsjson).

`install.sh` does not configure Hermes. A Hermes profile and a generated Hermes artifact are
kept in the source tree as a record of the contract, for a release that adds it.

## How to remove it

```sh
install.sh --uninstall
```

That removes the interview file wherever it finds one, the `cosift-onboarding` directory it
created if it is now empty, the `~/.local/bin/cosift-onboarding` command, the `settings.json`
entries and the installer's state files — together with the Cosift entry in each harness config.
There is no command that removes only onboarding, and `--uninstall --dry-run` is a usage error,
so there is no way to preview a removal.

Removing it by hand, including the `settings.json` entries and how to turn off only the
auto-start: [docs/UNINSTALL.md](../../docs/UNINSTALL.md#removing-the-onboarding-interview).

### Undoing what was recorded on the server

This part is asymmetric, and the difference matters:

- **A topic you only followed.** `cosift_topics("remove", ["first topic"])` deletes the account
  record. It is gone from `cosift_topics("list")`.
- **A topic you requested.** The same call reports success and clears the follow markers, but
  the account record survives, because Cosift keeps the request time so a later request cannot
  double-count the demand. The topic text, the time you asked and your reason line stay on your
  account, and the topic keeps appearing in `cosift_topics("list")` with `requested: true`.
  There is no tool on this surface that deletes it. Do not read `remove` as undoing a request.
- **Either way**, the topic text already written into the shared demand ledger stays there.

To forget the local record that onboarding is done, delete
`${XDG_CONFIG_HOME:-~/.config}/cosift/onboarding.json`, or, if the installer wrote one, set
`"onboarded": false` in `${XDG_CONFIG_HOME:-~/.config}/cosift/state.json`. `complete` also left
one `.cosift-backup-<UTC>` copy beside whichever file it rewrote; that one is yours to delete.
