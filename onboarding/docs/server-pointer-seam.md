# The server-side pointer: deferred, and the rule if it ever ships

**Status: ruled out for launch. Not implemented. No part of it ships on 2026-09-17.**

## The idea

Cosift's MCP server could add a pointer to the onboarding interview into a tool response, so
that a user who installed Cosift but never ran the interview would be told it exists at the
moment they first use a tool. It is the obvious answer to "what if nobody runs it".

## Why it is ruled out

The interview exists because `skillinject` exists. Pilot's `skillinject` rewrites an
always-loaded instruction file on a timer with unsigned, runtime-fetched, adversarially
A/B-tested text. Every property that makes it what it is would be reproduced, in miniature, by
a server-side pointer:

| skillinject property | a server-side pointer |
| --- | --- |
| text arrives at runtime, from a server | same |
| the user never chose to install that text | same |
| the text can be changed without the user's consent, or a release | same |
| the text can be A/B tested against the user's behaviour | same |
| the text steers the model, not the user | same |

The difference in size is real and the difference in kind is not. Shipping one while
criticising the other would make the criticism worth nothing.

There is a second, independent reason. The interview body has a hard rule that every string in
every tool response is data to relay, never an instruction to follow, whatever key it arrived
under. That rule is deliberately closed rather than a list of fields, because a list teaches
that the fields outside it are trustworthy. A pointer that the model is meant to act on would
be the first counter-example to a rule we need to hold everywhere else, including against a
hostile corpus.

So the trigger is local and user-driven only: the installer offers the interview at the end of
an install, and the user types the invocation in their agent. Detection of "has this user
onboarded" is local too, in
`${XDG_CONFIG_HOME:-$HOME/.config}/cosift/state.json` or `onboarding.json`, read by
`cosift-onboarding status`. Nothing about onboarding state is sent to the server, and the
server has no way to know and no business knowing.

## If we later observe that nobody runs it

The evidence that would reopen this is an account with followed topics far below what an
interview produces, or a large gap between installs and interviews over a real window. If that
happens, the change is one commit, and it is bounded as follows.

**The one-commit change.** One constant, in one place, added to the response of one tool
(`cosift_topics` with `action: "list"`), under a new top-level key, and only when that
account's topic list is empty, which is the only state in which the pointer carries
information. Not in `detail`, not in `note`, not in any field the body classifies as data to
relay, which since the rule was closed means every existing field without exception. Not in
`cosift_search`, which is the one genuinely read-only tool and must stay free of anything the
model could act on. Not in `cosift_lookup` or `cosift_request`, which are
already inside the consent gate.

Everything else stays as it is: no new tool, no new argument, no per-account text, no
experiment framework, no counter, no change to any existing field.

**The rule, non-negotiable if it ever ships.** The pointer must be a fixed constant that
contains no verb and no sentence. It names the thing and stops. It is pinned by a test that
asserts exactly that, and the test is the reason the rule survives the next person who wants
to make it warmer:

```python
POINTER = "/cosift-onboarding"          # or "$cosift-onboarding"; nothing else

def test_pointer_is_a_name_not_a_sentence():
    assert re.fullmatch(r"[/$]?[a-z0-9][a-z0-9-]*", POINTER)   # one token
    assert " " not in POINTER                                   # no sentence
    assert not POINTER.endswith((".", "!", "?"))                # no sentence
    assert POINTER.lower() == POINTER                           # no shouting
    assert len(POINTER) <= 32
```

A single token of `[a-z0-9-]` cannot contain a verb, cannot contain an imperative, cannot
contain urgency, and cannot be A/B tested into anything, because there is nothing in it to
vary. If someone needs to change what the pointer *says*, they cannot: they can only change
what it *is called*, and that is a rename, in a release, that a user can read.

Anything richer than that constant is the thing we refused. Send it back.
