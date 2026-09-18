#!/bin/sh
# 50-install: bin/install-onboarding.sh install, dry-run, force and uninstall.
set -u

CASE_DIR=$(cd "$(dirname "$0")" && pwd)

if [ -f "$CASE_DIR/00-lib.sh" ]; then
	# shellcheck disable=SC1091
	. "$CASE_DIR/00-lib.sh"
fi

if ! command -v assert_eq >/dev/null 2>&1; then
	CHECKS=0
	FAILURES=0
	note() { printf '   %s\n' "$*"; }
	pass_note() {
		CHECKS=$((CHECKS + 1))
		if [ "${ONB_VERBOSE:-0}" = 1 ]; then note "ok   $1"; fi
		return 0
	}
	fail_note() {
		CHECKS=$((CHECKS + 1))
		FAILURES=$((FAILURES + 1))
		note "FAIL $1"
		shift
		for _detail in "$@"; do note "       $_detail"; done
		return 0
	}
	assert_eq() {
		if [ "$1" = "$2" ]; then pass_note "$3"; else fail_note "$3" "expected: $1" "actual:   $2"; fi
	}
	finish() {
		if [ "$FAILURES" -eq 0 ]; then
			note "$CHECKS checks passed"
			exit 0
		fi
		note "$FAILURES of $CHECKS checks failed"
		exit 1
	}
fi

ONBOARDING=${ONB_ROOT:-$(cd "$CASE_DIR/../../.." && pwd)}
BIN=$ONBOARDING/bin/install-onboarding.sh

t_ok() { pass_note "$1"; }
t_bad() { fail_note "$1"; }
t_eq() { assert_eq "$3" "$2" "$1"; }

t_contains() {
	case $2 in
	*"$3"*) pass_note "$1" ;;
	*) fail_note "$1" "expected substring: $3" "actual: $2" ;;
	esac
}

t_exists() {
	if [ -e "$2" ]; then pass_note "$1"; else fail_note "$1" "missing: $2"; fi
}

t_absent() {
	if [ -e "$2" ]; then fail_note "$1" "still present: $2"; else pass_note "$1"; fi
}

WORK=$(mktemp -d) || exit 1
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

OUT=''
ERR=''
RC=0
run() {
	OUT=$("$@" 2>"$WORK/stderr")
	RC=$?
	ERR=$(cat "$WORK/stderr")
	return 0
}

sha_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		openssl dgst -sha256 "$1" | sed 's|.*= *||'
	fi
}

mode_of() {
	stat -c '%a' "$1" 2>/dev/null ||
		stat -f '%Lp' "$1" 2>/dev/null ||
		printf 'no-stat'
}

snapshot() {
	(
		cd "$1" 2>/dev/null || exit 0
		find . -print | LC_ALL=C sort | while read -r p; do
			if [ -L "$p" ]; then
				printf 'link %s\n' "$p"
			elif [ -d "$p" ]; then
				printf 'dir  %s %s\n' "$(mode_of "$p")" "$p"
			else
				printf 'file %s %s %s\n' "$(mode_of "$p")" "$(sha_of "$p")" "$p"
			fi
		done
	)
}

count_files() { find "$1" -type f 2>/dev/null | grep -c . ; }

backup_count() {
	_c=0
	for _f in "$1".cosift-backup-*; do
		[ -e "$_f" ] && _c=$((_c + 1))
	done
	printf '%s' "$_c"
}

fresh_prefix() {
	_p=$((${_p:-0} + 1))
	PREFIX="$WORK/prefix$_p"
	mkdir -p "$PREFIX"
}

# The real HOME must never be touched: everything goes through --prefix.
REAL_GUARD="$HOME/.claude/skills/cosift-onboarding"
REAL_GUARD_BEFORE=absent
[ -e "$REAL_GUARD" ] && REAL_GUARD_BEFORE=present

XDG_CONFIG_HOME="$WORK/xdg"
export XDG_CONFIG_HOME
mkdir -p "$XDG_CONFIG_HOME"

# --- synthetic fixture ------------------------------------------------------
GEN="$WORK/gen"
mkdir -p "$GEN/claude/cosift-onboarding" "$GEN/codex/cosift-onboarding" \
	"$GEN/hermes/cosift-onboarding" "$GEN/opencode"

for h in claude codex hermes; do
	cat >"$GEN/$h/cosift-onboarding/SKILL.md" <<EOF
---
name: cosift-onboarding
description: fixture for $h
---
body for $h
EOF
done
cat >"$GEN/opencode/cosift-onboarding.md" <<'EOF'
---
description: fixture for opencode
---
body for opencode
EOF

write_manifest() {
	cat >"$GEN/MANIFEST.json" <<EOF
{
  "artifact": "cosift-onboarding",
  "version": "test",
  "file_mode": "0644",
  "dir_mode": "0755",
  "harnesses": [
    {
      "harness": "claude",
      "install_path": "\$HOME/.claude/skills/cosift-onboarding/SKILL.md",
      "owned_dir": "\$HOME/.claude/skills/cosift-onboarding",
      "shared_parent": "\$HOME/.claude/skills",
      "generated_path": "claude/cosift-onboarding/SKILL.md",
      "sha256": "$(sha_of "$GEN/claude/cosift-onboarding/SKILL.md")"
    },
    {
      "harness": "codex",
      "install_path": "\$HOME/.agents/skills/cosift-onboarding/SKILL.md",
      "owned_dir": "\$HOME/.agents/skills/cosift-onboarding",
      "shared_parent": "\$HOME/.agents/skills",
      "generated_path": "codex/cosift-onboarding/SKILL.md",
      "sha256": "$(sha_of "$GEN/codex/cosift-onboarding/SKILL.md")"
    },
    {
      "harness": "hermes",
      "install_path": "\${HERMES_HOME:-\$HOME/.hermes}/skills/cosift-onboarding/SKILL.md",
      "owned_dir": "\${HERMES_HOME:-\$HOME/.hermes}/skills/cosift-onboarding",
      "shared_parent": "\${HERMES_HOME:-\$HOME/.hermes}/skills",
      "generated_path": "hermes/cosift-onboarding/SKILL.md",
      "sha256": "$(sha_of "$GEN/hermes/cosift-onboarding/SKILL.md")"
    },
    {
      "harness": "opencode",
      "install_path": "\${XDG_CONFIG_HOME:-\$HOME/.config}/opencode/commands/cosift-onboarding.md",
      "shared_parent": "\${XDG_CONFIG_HOME:-\$HOME/.config}/opencode/commands",
      "generated_path": "opencode/cosift-onboarding.md",
      "sha256": "$(sha_of "$GEN/opencode/cosift-onboarding.md")"
    }
  ]
}
EOF
}
write_manifest
MF="$GEN/MANIFEST.json"

# --- install ----------------------------------------------------------------
fresh_prefix
CLAUDE_TARGET="$PREFIX$HOME/.claude/skills/cosift-onboarding/SKILL.md"
CLAUDE_DIR="$PREFIX$HOME/.claude/skills/cosift-onboarding"
CLAUDE_PARENT="$PREFIX$HOME/.claude/skills"

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF"
t_eq 'install: exit 0' "$RC" 0
t_contains 'install: reports installed' "$OUT" installed
t_exists 'install: file at the contract path' "$CLAUDE_TARGET"
t_eq 'install: exactly one file under the prefix' "$(count_files "$PREFIX")" 1
t_eq 'install: file mode 0644' "$(mode_of "$CLAUDE_TARGET")" 644
t_eq 'install: our directory mode 0755' "$(mode_of "$CLAUDE_DIR")" 755
t_eq 'install: shared parent mode 0755' "$(mode_of "$CLAUDE_PARENT")" 755
t_eq 'install: content matches the generated file' \
	"$(sha_of "$CLAUDE_TARGET")" "$(sha_of "$GEN/claude/cosift-onboarding/SKILL.md")"

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF"
t_eq 'second install: exit 0' "$RC" 0
t_contains 'second install: reports unchanged' "$OUT" unchanged
t_eq 'second install: no backup' "$(backup_count "$CLAUDE_TARGET")" 0
t_eq 'second install: still one file' "$(count_files "$PREFIX")" 1

# --- dry-run writes nothing -------------------------------------------------
before=$(snapshot "$PREFIX")
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --dry-run
t_eq 'dry-run over an installed tree: exit 0' "$RC" 0
after=$(snapshot "$PREFIX")
if [ "$before" = "$after" ]; then
	t_ok 'dry-run over an installed tree: prefix unchanged'
else
	t_bad "dry-run changed the tree: $(printf '%s\n%s\n' "$before" "$after" | sort | uniq -u | tr '\n' ' ')"
fi

fresh_prefix
before=$(snapshot "$PREFIX")
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --dry-run
t_eq 'dry-run on an empty tree: exit 0' "$RC" 0
t_contains 'dry-run: says what it would install' "$OUT" 'would install'
t_contains 'dry-run: shows a unified diff' "$OUT" '+name: cosift-onboarding'
after=$(snapshot "$PREFIX")
t_eq 'dry-run: created no directories' "$before" "$after"
t_eq 'dry-run: created no files' "$(count_files "$PREFIX")" 0

# --- a foreign file at our path ---------------------------------------------
fresh_prefix
CLAUDE_TARGET="$PREFIX$HOME/.claude/skills/cosift-onboarding/SKILL.md"
CLAUDE_DIR="$PREFIX$HOME/.claude/skills/cosift-onboarding"
CLAUDE_PARENT="$PREFIX$HOME/.claude/skills"
mkdir -p "$CLAUDE_DIR"
printf 'hand written skill, not ours\n' >"$CLAUDE_TARGET"
foreign_sha=$(sha_of "$CLAUDE_TARGET")

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF"
t_eq 'foreign file: refused' "$RC" 1
t_contains 'foreign file: says refusing' "$ERR" refusing
t_eq 'foreign file: left untouched' "$(sha_of "$CLAUDE_TARGET")" "$foreign_sha"
t_eq 'foreign file: no backup made on refusal' "$(backup_count "$CLAUDE_TARGET")" 0

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --force
t_eq 'foreign file: --force installs' "$RC" 0
t_eq 'foreign file: one backup' "$(backup_count "$CLAUDE_TARGET")" 1
t_eq 'foreign file: our content is in place' \
	"$(sha_of "$CLAUDE_TARGET")" "$(sha_of "$GEN/claude/cosift-onboarding/SKILL.md")"
for f in "$CLAUDE_TARGET".cosift-backup-*; do
	t_eq 'foreign file: backup holds the original bytes' "$(sha_of "$f")" "$foreign_sha"
	rm -f "$f"
done

# --- uninstall --------------------------------------------------------------
mkdir -p "$CLAUDE_PARENT/other-skill"
printf 'a sibling skill\n' >"$CLAUDE_PARENT/other-skill/SKILL.md"
sibling_sha=$(sha_of "$CLAUDE_PARENT/other-skill/SKILL.md")

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --uninstall
t_eq 'uninstall: exit 0' "$RC" 0
t_absent 'uninstall: our file is gone' "$CLAUDE_TARGET"
t_absent 'uninstall: our empty directory is gone' "$CLAUDE_DIR"
t_exists 'uninstall: shared parent survives' "$CLAUDE_PARENT"
t_exists 'uninstall: sibling skill survives' "$CLAUDE_PARENT/other-skill/SKILL.md"
t_eq 'uninstall: sibling is byte-identical' \
	"$(sha_of "$CLAUDE_PARENT/other-skill/SKILL.md")" "$sibling_sha"

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --uninstall
t_eq 'uninstall twice: exit 0' "$RC" 0
t_contains 'uninstall twice: reports not installed' "$OUT" 'not installed'

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF"
printf 'a note the user left\n' >"$CLAUDE_DIR/NOTES.md"
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --uninstall
t_eq 'uninstall: exit 0 with a leftover file' "$RC" 0
t_exists 'uninstall: keeps a directory that still holds something' "$CLAUDE_DIR/NOTES.md"

# --- opencode collision guard -----------------------------------------------
fresh_prefix
OC_TARGET="$PREFIX$XDG_CONFIG_HOME/opencode/commands/cosift-onboarding.md"
OC_RIVAL="$PREFIX$XDG_CONFIG_HOME/opencode/command/cosift-onboarding.md"
mkdir -p "$(dirname "$OC_RIVAL")"
printf 'a rival command\n' >"$OC_RIVAL"

run "$BIN" --harness opencode --prefix "$PREFIX" --manifest "$MF"
t_eq 'opencode: singular command/ collision refused' "$RC" 1
t_contains 'opencode: explains the collision' "$ERR" 'command/'
t_absent 'opencode: nothing installed on refusal' "$OC_TARGET"

run "$BIN" --harness opencode --prefix "$PREFIX" --manifest "$MF" --force
t_eq 'opencode: --force installs anyway' "$RC" 0
t_exists 'opencode: file at the commands/ path' "$OC_TARGET"

run "$BIN" --harness opencode --prefix "$PREFIX" --manifest "$MF" --uninstall
t_eq 'opencode: uninstall exit 0' "$RC" 0
t_absent 'opencode: our command file is gone' "$OC_TARGET"
t_exists 'opencode: commands/ directory survives' "$(dirname "$OC_TARGET")"
t_exists 'opencode: the rival file is untouched' "$OC_RIVAL"

# --- hermes and the codex override ------------------------------------------
fresh_prefix
run "$BIN" --harness hermes --prefix "$PREFIX" --manifest "$MF"
t_eq 'hermes: installs' "$RC" 0
t_contains 'hermes: warns UNVERIFIED' "$ERR" UNVERIFIED
t_exists 'hermes: file in place' "$PREFIX$HOME/.hermes/skills/cosift-onboarding/SKILL.md"

run "$BIN" --harness codex --prefix "$PREFIX" --manifest "$MF" --codex-skills-dir /opt/agents/skills
t_eq 'codex: --codex-skills-dir honoured' "$RC" 0
t_exists 'codex: file under the override dir' "$PREFIX/opt/agents/skills/cosift-onboarding/SKILL.md"
run "$BIN" --harness codex --prefix "$PREFIX" --manifest "$MF" --codex-skills-dir /opt/agents/skills --uninstall
t_absent 'codex: override dir uninstall removes our dir' "$PREFIX/opt/agents/skills/cosift-onboarding"
t_exists 'codex: override shared parent survives' "$PREFIX/opt/agents/skills"

# --- refusals ---------------------------------------------------------------
fresh_prefix
printf 'tampered\n' >>"$GEN/claude/cosift-onboarding/SKILL.md"
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF"
t_eq 'checksum mismatch: refused' "$RC" 1
t_contains 'checksum mismatch: explains why' "$ERR" 'checksum mismatch'
t_eq 'checksum mismatch: wrote nothing' "$(count_files "$PREFIX")" 0
write_manifest

cat >"$WORK/evil.json" <<EOF
{"harnesses": {"claude": {"install_path": "\$HOME/.claude/CLAUDE.md",
 "generated_path": "claude/cosift-onboarding/SKILL.md",
 "sha256": "$(sha_of "$GEN/claude/cosift-onboarding/SKILL.md")"}}}
EOF
cp "$WORK/evil.json" "$GEN/evil.json"
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$GEN/evil.json"
t_eq 'deny-list: an instruction-file target is refused' "$RC" 1
t_contains 'deny-list: names the reason' "$ERR" 'instruction file'
t_absent 'deny-list: nothing written' "$PREFIX$HOME/.claude/CLAUDE.md"

run "$BIN" --harness nosuch --prefix "$PREFIX" --manifest "$MF"
t_eq 'unknown harness: usage exit 2' "$RC" 2
run "$BIN" --prefix "$PREFIX" --manifest "$MF"
t_eq 'missing --harness: usage exit 2' "$RC" 2
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$WORK/nope.json"
t_eq 'missing manifest: non-zero' "$RC" 1

# --- manifest shape tolerance -----------------------------------------------
cat >"$GEN/alt.json" <<EOF
{"harnesses": {"claude": {"install_path": "\$HOME/.claude/skills/cosift-onboarding/SKILL.md",
 "owned_dir": "\$HOME/.claude/skills/cosift-onboarding",
 "shared_parent": "\$HOME/.claude/skills",
 "source": "claude/cosift-onboarding/SKILL.md",
 "sha256": "$(sha_of "$GEN/claude/cosift-onboarding/SKILL.md")"}}}
EOF
fresh_prefix
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$GEN/alt.json"
t_eq 'manifest as a dict of harnesses: installs' "$RC" 0
t_exists 'manifest as a dict of harnesses: file in place' \
	"$PREFIX$HOME/.claude/skills/cosift-onboarding/SKILL.md"

# --- uninstall never destroys an edited file without a copy -----------------
fresh_prefix
CLAUDE_TARGET="$PREFIX$HOME/.claude/skills/cosift-onboarding/SKILL.md"
CLAUDE_DIR="$PREFIX$HOME/.claude/skills/cosift-onboarding"
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF"
t_eq 'edited uninstall: installed first' "$RC" 0
printf 'a hard rule the user added to cosift-onboarding\n' >>"$CLAUDE_TARGET"
edited_sha=$(sha_of "$CLAUDE_TARGET")

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --uninstall --dry-run
t_eq 'edited uninstall: dry-run exit 0' "$RC" 0
t_contains 'edited uninstall: dry-run says it would back up' "$OUT" 'would back up'
t_eq 'edited uninstall: dry-run wrote nothing' "$(sha_of "$CLAUDE_TARGET")" "$edited_sha"
t_eq 'edited uninstall: dry-run made no backup' "$(backup_count "$CLAUDE_TARGET")" 0

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --uninstall
t_eq 'edited uninstall: exit 0' "$RC" 0
t_absent 'edited uninstall: the file is gone' "$CLAUDE_TARGET"
t_eq 'edited uninstall: exactly one backup' "$(backup_count "$CLAUDE_TARGET")" 1
t_contains 'edited uninstall: names the backup on stdout' "$OUT" 'backed up '
for f in "$CLAUDE_TARGET".cosift-backup-*; do
	t_eq 'edited uninstall: the backup holds the edited bytes' "$(sha_of "$f")" "$edited_sha"
done
t_exists 'edited uninstall: the directory survives, it still holds the backup' "$CLAUDE_DIR"

run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --uninstall
t_contains 'edited uninstall: a later run reports the leftover backup' "$OUT" 'left in place '

# A byte-identical file is still removed with no backup at all.
fresh_prefix
CLAUDE_TARGET="$PREFIX$HOME/.claude/skills/cosift-onboarding/SKILL.md"
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF"
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$MF" --uninstall
t_eq 'clean uninstall: no backup for our own bytes' "$(backup_count "$CLAUDE_TARGET")" 0
t_eq 'clean uninstall: prefix is empty again' "$(count_files "$PREFIX")" 0

# --- COSIFT_CODEX_SKILLS_DIR is honoured, not just the flag -----------------
fresh_prefix
COSIFT_CODEX_SKILLS_DIR=/opt/env-agents/skills
export COSIFT_CODEX_SKILLS_DIR
run "$BIN" --harness codex --prefix "$PREFIX" --manifest "$MF"
t_eq 'codex env override: exit 0' "$RC" 0
t_exists 'codex env override: file under the env dir' \
	"$PREFIX/opt/env-agents/skills/cosift-onboarding/SKILL.md"
t_absent 'codex env override: default dir untouched' "$PREFIX$HOME/.agents/skills"
env_paths=$("$ONBOARDING/bin/cosift-onboarding" paths | awk -F'\t' '$1=="codex"{print $2}')
t_eq 'codex env override: paths agrees with the installer' \
	"$env_paths" /opt/env-agents/skills/cosift-onboarding/SKILL.md
run "$BIN" --harness codex --prefix "$PREFIX" --manifest "$MF" --codex-skills-dir /opt/flag-agents/skills
t_exists 'codex env override: the flag still wins' \
	"$PREFIX/opt/flag-agents/skills/cosift-onboarding/SKILL.md"
run "$BIN" --harness codex --prefix "$PREFIX" --manifest "$MF" --uninstall
t_absent 'codex env override: uninstall removes our env-dir install' \
	"$PREFIX/opt/env-agents/skills/cosift-onboarding"
t_exists 'codex env override: env shared parent survives' "$PREFIX/opt/env-agents/skills"
unset COSIFT_CODEX_SKILLS_DIR

# --- a manifest cannot dictate a mode ---------------------------------------
fresh_prefix
cat >"$GEN/badmode.json" <<EOF
{"file_mode": "0777", "dir_mode": "0755", "harnesses": [
 {"harness": "claude",
  "install_path": "\$HOME/.claude/skills/cosift-onboarding/SKILL.md",
  "owned_dir": "\$HOME/.claude/skills/cosift-onboarding",
  "shared_parent": "\$HOME/.claude/skills",
  "generated_path": "claude/cosift-onboarding/SKILL.md",
  "sha256": "$(sha_of "$GEN/claude/cosift-onboarding/SKILL.md")"}]}
EOF
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$GEN/badmode.json"
t_eq 'manifest mode 0777: refused' "$RC" 1
t_contains 'manifest mode 0777: names the mode' "$ERR" '0777'
t_eq 'manifest mode 0777: wrote nothing' "$(count_files "$PREFIX")" 0

cat >"$GEN/baddir.json" <<EOF
{"file_mode": "0644", "dir_mode": "0777", "harnesses": [
 {"harness": "claude",
  "install_path": "\$HOME/.claude/skills/cosift-onboarding/SKILL.md",
  "owned_dir": "\$HOME/.claude/skills/cosift-onboarding",
  "shared_parent": "\$HOME/.claude/skills",
  "generated_path": "claude/cosift-onboarding/SKILL.md",
  "sha256": "$(sha_of "$GEN/claude/cosift-onboarding/SKILL.md")"}]}
EOF
run "$BIN" --harness claude --prefix "$PREFIX" --manifest "$GEN/baddir.json"
t_eq 'manifest dir_mode 0777: refused' "$RC" 1
t_eq 'manifest dir_mode 0777: wrote nothing' "$(count_files "$PREFIX")" 0

# --- the real generated tree ------------------------------------------------
REAL_MF="$ONBOARDING/generated/MANIFEST.json"
if [ ! -d "$ONBOARDING/generated" ] || [ ! -f "$REAL_MF" ]; then
	note "SKIP the real generated tree: $REAL_MF does not exist yet"
else
	for h in claude codex opencode hermes; do
		fresh_prefix
		run "$BIN" --harness "$h" --prefix "$PREFIX"
		t_eq "real manifest: $h installs" "$RC" 0
		t_eq "real manifest: $h installs exactly one file" "$(count_files "$PREFIX")" 1
		real_target=$(find "$PREFIX" -type f 2>/dev/null)
		t_eq "real manifest: $h file mode 0644" "$(mode_of "$real_target")" 644
		run "$BIN" --harness "$h" --prefix "$PREFIX"
		t_contains "real manifest: $h second install is unchanged" "$OUT" unchanged
		run "$BIN" --harness "$h" --prefix "$PREFIX" --uninstall
		t_eq "real manifest: $h uninstalls cleanly" "$(count_files "$PREFIX")" 0
	done
fi

# --- the real HOME was never touched ----------------------------------------
REAL_GUARD_AFTER=absent
[ -e "$REAL_GUARD" ] && REAL_GUARD_AFTER=present
t_eq 'the real HOME was not touched' "$REAL_GUARD_AFTER" "$REAL_GUARD_BEFORE"

finish
