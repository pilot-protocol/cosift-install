# Handoff: Cosift installer

Everything the site needs in order to publish the Cosift installer. Copy-paste from here.

## The install command

```
curl -fsSL https://raw.githubusercontent.com/pilot-protocol/cosift-install/v1/install.sh | sh
```

Publish it exactly as written, including `-fsSL` and the `v1` tag. Please render it as a
copyable code block rather than prose, and don't line-wrap it.

## Description (adapt freely)

> Cosift is a curated reference corpus that AI agents can consult while they work — a
> Wikipedia for agents. Instead of answering from memory, the agent looks the subject up and
> grounds its answer in the curated article. One command registers Cosift with the AI coding
> tools you already have installed.

Shorter variant for a card or a meta description:

> A curated reference corpus AI agents can look things up in, instead of guessing. One command
> to connect it to the tools you already use.

## Supported tools

- Claude Code
- Codex CLI
- opencode

List exactly these three. The installer works on Linux and macOS.

If the user accepts the optional onboarding interview during the install, their agent also
gains a `/cosift-onboarding` command (`$cosift-onboarding` on Codex).

## Links

| | |
| --- | --- |
| Source and documentation | `https://github.com/pilot-protocol/cosift-install` |
| Uninstall instructions | `https://github.com/pilot-protocol/cosift-install/blob/v1/docs/UNINSTALL.md` |
| Support / bug reports | Issues on the repository above |

The README covers installation, every option and exit code, what the script reads and writes,
troubleshooting, and revocation. Point support questions at it rather than duplicating its
contents on the site — one copy stays accurate, two do not.

## Two points worth keeping in any copy you write

- The installer sends **no telemetry** and contacts only the two Cosift endpoints. This is a
  genuine differentiator for a piped-to-shell installer and is safe to state plainly.
- After install, the credential is stored **in cleartext in the tool's own config file** —
  that is how MCP headers work everywhere. The README says so prominently. Don't write copy
  that implies the credential is stored more securely than that.

Please don't promise that a verification email will arrive, or give a delivery time. The auth
service deliberately returns the same response whether or not an address can be mailed (it is
an anti-enumeration defence), so "check your inbox" is the strongest claim that is true. There
is also a cap of three codes per address per hour, which the README explains.

## About the `v1` tag

`v1` is a **movable** tag. When we ship a fix we move `v1` to the new commit, and the published
command picks it up automatically — no site edit, no changed URL, nothing for you to do.

One caveat: `raw.githubusercontent.com` caches for roughly five minutes, so for a few minutes
after a release some users still receive the previous script. That is expected. If someone
reports a bug we have just fixed, ask them to wait five minutes and re-run before investigating
further.

Do not replace `v1` in the published command with a specific version number. Pinned versions
are documented in the README for users who want them, but the site should stay on `v1` so that
fixes reach people without a deploy.
