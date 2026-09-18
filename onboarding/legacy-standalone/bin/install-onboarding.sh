#!/bin/sh
# install-onboarding.sh: install, preview or remove the cosift-onboarding skill.
set -u

PROG=install-onboarding.sh
ARTIFACT=cosift-onboarding
HARNESS_LIST='claude codex opencode hermes'
DENY_BASENAMES='claude.md agents.md agents.override.md soul.md'

EX_FAIL=1
EX_USAGE=2

TMPF=''
HOME=${HOME:-}
PY=''

HARNESS=''
DRY_RUN=0
UNINSTALL=0
FORCE=0
CODEX_DIR=''
PREFIX=''
MANIFEST=''

cleanup() {
	if [ -n "$TMPF" ]; then
		rm -f "$TMPF" 2>/dev/null
	fi
	return 0
}
trap cleanup EXIT INT TERM HUP

warn() { printf '%s: %s\n' "$PROG" "$*" >&2; }

fail() {
	warn "$*"
	exit "$EX_FAIL"
}

usage() {
	cat <<'EOF'
Usage:
  install-onboarding.sh --harness <claude|codex|opencode|hermes> [options]

Options:
  --harness NAME          target harness (required)
  --dry-run               print a unified diff of what would change; write nothing
  --uninstall             remove the installed file
  --force                 overwrite (or remove) a file that is not ours, after
                          backing it up; also overrides the opencode collision guard
  --codex-skills-dir DIR  use DIR instead of ~/.agents/skills. The environment
                          variable COSIFT_CODEX_SKILLS_DIR does the same thing;
                          the flag wins when both are set
  --prefix DIR            reroot every install path under DIR (for testing)
  --manifest PATH         use PATH instead of <script dir>/../generated/MANIFEST.json
  --help                  this text

Install paths (one file per harness, taken from the manifest):
  claude    $HOME/.claude/skills/cosift-onboarding/SKILL.md
  codex     $HOME/.agents/skills/cosift-onboarding/SKILL.md
  opencode  ${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands/cosift-onboarding.md
  hermes    ${HERMES_HOME:-$HOME/.hermes}/skills/cosift-onboarding/SKILL.md

Behaviour:
  The file is checked against the sha256 recorded next to it in MANIFEST.json,
  which catches a corrupted, truncated or stale copy. It is not a signature and
  it does not authenticate the manifest itself: a manifest and the file it
  describes are trusted together or not at all. The manifest's file and
  directory modes are not trusted, only 0644 and 0755 are accepted.

  An install that would not change the file reports "unchanged" and writes
  nothing, including no backup. A different file already at our path is refused
  unless --force, which first copies it to <path>.cosift-backup-<UTC>.
  --uninstall likewise backs up anything that is not byte-identical to the file
  we ship before removing it. Backups are never deleted, and --uninstall prints
  "left in place <path>" for each one it can still see.

  --dry-run never creates a directory, a backup or a file. It exits 0 whenever it
  can work out a plan, including the plans it reports as refusals, and non-zero
  only when it cannot (bad arguments, missing manifest, checksum mismatch).

  opencode scans both "command/" and "commands/". If a rival
  cosift-onboarding.md already exists under "command/", installing ours under
  "commands/" would register the same command name twice, so we refuse unless
  --force.

  hermes has not been verified against a running install; the harness must be
  named explicitly and a warning is printed.

  --uninstall removes our file and then our own cosift-onboarding directory if
  it is empty. The shared parent (~/.claude/skills, ~/.agents/skills,
  ~/.config/opencode/commands, ~/.hermes/skills) is never removed, and neither
  is a directory holding anything else.

  No network access. Never writes to CLAUDE.md, AGENTS.md, AGENTS.override.md
  or SOUL.md. Reading the manifest needs python3 (or python).
EOF
}

# ---------------------------------------------------------------- paths ----

cfg_home() {
	if [ -n "${XDG_CONFIG_HOME:-}" ]; then
		printf '%s' "$XDG_CONFIG_HOME"
	else
		printf '%s' "$HOME/.config"
	fi
}

hermes_home() {
	if [ -n "${HERMES_HOME:-}" ]; then
		printf '%s' "$HERMES_HOME"
	else
		printf '%s' "$HOME/.hermes"
	fi
}

codex_skills_dir() {
	if [ -n "$CODEX_DIR" ]; then
		printf '%s' "$CODEX_DIR"
	elif [ -n "${COSIFT_CODEX_SKILLS_DIR:-}" ]; then
		printf '%s' "$COSIFT_CODEX_SKILLS_DIR"
	else
		printf '%s' "$HOME/.agents/skills"
	fi
}

script_dir() {
	_d=${0%/*}
	if [ "$_d" = "$0" ]; then
		_d=.
	fi
	(cd "$_d" 2>/dev/null && pwd) || printf '%s' "$_d"
}

expand_path() {
	_p=$1
	case $_p in
	[~]) _p=$HOME ;;
	[~]/*) _p="$HOME/${_p#?/}" ;;
	esac
	case $_p in
	*'$'* | *'~'*)
		_p=$(printf '%s' "$_p" | sed \
			-e "s|\${XDG_CONFIG_HOME:-~/.config}|$(cfg_home)|g" \
			-e "s|\${XDG_CONFIG_HOME:-\$HOME/.config}|$(cfg_home)|g" \
			-e "s|\${XDG_CONFIG_HOME}|$(cfg_home)|g" \
			-e "s|\$XDG_CONFIG_HOME|$(cfg_home)|g" \
			-e "s|\${HERMES_HOME:-~/.hermes}|$(hermes_home)|g" \
			-e "s|\${HERMES_HOME:-\$HOME/.hermes}|$(hermes_home)|g" \
			-e "s|\${HERMES_HOME}|$(hermes_home)|g" \
			-e "s|\$HERMES_HOME|$(hermes_home)|g" \
			-e "s|\${HOME}|$HOME|g" \
			-e "s|\$HOME|$HOME|g" \
			-e "s|^~/|$HOME/|")
		;;
	esac
	printf '%s' "$_p"
}

reroot() {
	if [ -z "$PREFIX" ]; then
		printf '%s' "$1"
		return 0
	fi
	case $1 in
	/*) printf '%s%s' "${PREFIX%/}" "$1" ;;
	*) printf '%s/%s' "${PREFIX%/}" "$1" ;;
	esac
}

default_target() {
	case $1 in
	claude) printf '%s' "$HOME/.claude/skills/$ARTIFACT/SKILL.md" ;;
	codex) printf '%s' "$(codex_skills_dir)/$ARTIFACT/SKILL.md" ;;
	opencode) printf '%s' "$(cfg_home)/opencode/commands/$ARTIFACT.md" ;;
	hermes) printf '%s' "$(hermes_home)/skills/$ARTIFACT/SKILL.md" ;;
	esac
}

default_shared_parent() {
	case $1 in
	claude) printf '%s' "$HOME/.claude/skills" ;;
	codex) printf '%s' "$(codex_skills_dir)" ;;
	opencode) printf '%s' "$(cfg_home)/opencode/commands" ;;
	hermes) printf '%s' "$(hermes_home)/skills" ;;
	esac
}

basename_of() { printf '%s' "${1##*/}"; }

dirname_of() {
	case $1 in
	*/*) printf '%s' "${1%/*}" ;;
	*) printf '.' ;;
	esac
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --------------------------------------------------------------- python ----

find_python() {
	for _c in python3 python; do
		if command -v "$_c" >/dev/null 2>&1; then
			if "$_c" -c 'import json,sys;sys.exit(0)' >/dev/null 2>&1; then
				PY=$_c
				return 0
			fi
		fi
	done
	PY=''
	return 1
}

read_entry() {
	"$PY" - "$1" "$2" <<'PYEOF'
import json, sys

NAME_KEYS = ('harness', 'name', 'id', 'harness_name')
GROUP_KEYS = ('harnesses', 'artifacts', 'files', 'targets', 'entries')
INSTALL_KEYS = ('install_path', 'target_path', 'target', 'destination', 'dest', 'path', 'install')
SOURCE_KEYS = ('generated_path', 'source', 'source_path', 'src', 'artifact_path', 'file', 'relpath')
SHA_KEYS = ('sha256', 'sha', 'hash', 'digest', 'checksum')
OWNED_KEYS = ('owned_dir', 'own_dir', 'skill_dir', 'directory')
PARENT_KEYS = ('shared_parent', 'parent', 'shared_dir')
FILE_MODE_KEYS = ('file_mode', 'mode')
DIR_MODE_KEYS = ('dir_mode',)

path, wanted = sys.argv[1], sys.argv[2]
try:
    fh = open(path, 'rb')
    manifest = json.loads(fh.read().decode('utf-8'))
    fh.close()
except Exception as exc:
    sys.stderr.write('manifest is not readable JSON: %s\n' % exc)
    sys.exit(2)


def pick(entry, keys, top=None):
    for source in (entry, top):
        if not isinstance(source, dict):
            continue
        for key in keys:
            value = source.get(key)
            if isinstance(value, str) and value:
                return value
    return ''


def collect(node, found):
    if isinstance(node, dict):
        for key in GROUP_KEYS:
            child = node.get(key)
            if isinstance(child, dict):
                for name, entry in child.items():
                    if isinstance(entry, dict):
                        found.setdefault(name, entry)
                return
            if isinstance(child, list):
                collect(child, found)
                return
        for name, entry in node.items():
            if isinstance(entry, dict) and name == wanted:
                found.setdefault(name, entry)
    elif isinstance(node, list):
        for entry in node:
            if isinstance(entry, dict):
                name = pick(entry, NAME_KEYS)
                if name:
                    found.setdefault(name, entry)


found = {}
collect(manifest, found)
entry = found.get(wanted)
if entry is None:
    sys.stderr.write('manifest has no entry for harness %s\n' % wanted)
    sys.exit(1)

top = manifest if isinstance(manifest, dict) else None
for value in (
    wanted,
    pick(entry, INSTALL_KEYS),
    pick(entry, SOURCE_KEYS),
    pick(entry, SHA_KEYS),
    pick(entry, OWNED_KEYS),
    pick(entry, PARENT_KEYS),
    pick(entry, FILE_MODE_KEYS, top),
    pick(entry, DIR_MODE_KEYS, top),
):
    sys.stdout.write(value.replace('\n', ' ') + '\n')
PYEOF
}

# --------------------------------------------------------------- sha256 ----

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
		return 0
	fi
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
		return 0
	fi
	if command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$1" | sed 's|.*= *||'
		return 0
	fi
	if [ -n "$PY" ]; then
		"$PY" - "$1" <<'PYEOF'
import hashlib, sys
digest = hashlib.sha256()
fh = open(sys.argv[1], 'rb')
while True:
    chunk = fh.read(65536)
    if not chunk:
        break
    digest.update(chunk)
fh.close()
sys.stdout.write(digest.hexdigest() + '\n')
PYEOF
		return 0
	fi
	return 1
}

# ------------------------------------------------------------- planning ----

plan() {
	_mf=$MANIFEST
	if [ -z "$_mf" ]; then
		_root=$(cd "$(script_dir)/.." 2>/dev/null && pwd) || _root=$(script_dir)/..
		_mf=$_root/generated/MANIFEST.json
	fi
	if [ ! -r "$_mf" ]; then
		fail "manifest not found: $_mf (run the generator first)"
	fi
	MANIFEST=$_mf
	MANIFEST_DIR=$(dirname_of "$_mf")
	MANIFEST_ROOT=$(cd "$MANIFEST_DIR/.." 2>/dev/null && pwd) || MANIFEST_ROOT=$MANIFEST_DIR

	if [ -z "$PY" ]; then
		fail "python3 (or python) is required to read $_mf"
	fi

	_out=$(read_entry "$_mf" "$HARNESS") || fail "cannot read $_mf for harness $HARNESS"
	{
		read -r _e_harness
		read -r _e_install
		read -r _e_source
		read -r _e_sha
		read -r _e_owned
		read -r _e_parent
		read -r _e_fmode
		read -r _e_dmode
	} <<EOF
$_out
EOF

	if [ -n "$_e_harness" ] && [ "$_e_harness" != "$HARNESS" ]; then
		fail "manifest entry mismatch: asked for $HARNESS, got $_e_harness"
	fi
	if [ -z "$_e_install" ]; then
		_e_install=$(default_target "$HARNESS")
	fi
	if [ -z "$_e_parent" ]; then
		_e_parent=$(default_shared_parent "$HARNESS")
	fi
	if [ -z "$_e_fmode" ]; then
		_e_fmode=0644
	fi
	if [ -z "$_e_dmode" ]; then
		_e_dmode=0755
	fi

	SOURCE=''
	if [ -n "$_e_source" ]; then
		case $_e_source in
		/*)
			SOURCE=$_e_source
			;;
		*)
			if [ -f "$MANIFEST_DIR/$_e_source" ]; then
				SOURCE=$MANIFEST_DIR/$_e_source
			elif [ -f "$MANIFEST_ROOT/$_e_source" ]; then
				SOURCE=$MANIFEST_ROOT/$_e_source
			fi
			;;
		esac
	fi
	if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
		_found=$(find "$MANIFEST_DIR/$HARNESS" -type f 2>/dev/null)
		if [ "$(printf '%s\n' "$_found" | grep -c .)" = 1 ]; then
			SOURCE=$_found
		fi
	fi
	if [ -z "$SOURCE" ] || [ ! -f "$SOURCE" ]; then
		fail "generated file for $HARNESS not found (manifest says: ${_e_source:-<nothing>})"
	fi

	if [ -z "$_e_sha" ]; then
		fail "manifest has no sha256 for $HARNESS; refusing to install unverified content"
	fi
	_got=$(sha256_of "$SOURCE") || fail 'no sha256 tool available (sha256sum, shasum, openssl or python)'
	if [ "$_got" != "$_e_sha" ]; then
		fail "checksum mismatch for $SOURCE: manifest says $_e_sha, file is $_got"
	fi

	case $_e_fmode in
	0644) : ;;
	*) fail "refusing: manifest file_mode is $_e_fmode, expected 0644" ;;
	esac
	case $_e_dmode in
	0755) : ;;
	*) fail "refusing: manifest dir_mode is $_e_dmode, expected 0755" ;;
	esac

	if [ "$HARNESS" = codex ] && { [ -n "$CODEX_DIR" ] || [ -n "${COSIFT_CODEX_SKILLS_DIR:-}" ]; }; then
		_cdir=$(codex_skills_dir)
		_e_install="$_cdir/$ARTIFACT/SKILL.md"
		_e_owned="$_cdir/$ARTIFACT"
		_e_parent=$_cdir
	fi

	_abs=$(expand_path "$_e_install")
	case $_abs in
	/*) : ;;
	*) fail "refusing: install path is not absolute: $_abs" ;;
	esac
	TARGET=$(reroot "$_abs")
	SHARED_PARENT=$(reroot "$(expand_path "$_e_parent")")
	if [ -n "$_e_owned" ]; then
		OWNED_DIR=$(reroot "$(expand_path "$_e_owned")")
	else
		OWNED_DIR=''
	fi
	FILE_MODE=$_e_fmode
	DIR_MODE=$_e_dmode
	TARGET_DIR=$(dirname_of "$TARGET")

	if [ -z "$OWNED_DIR" ] && [ "$(basename_of "$TARGET_DIR")" = "$ARTIFACT" ]; then
		OWNED_DIR=$TARGET_DIR
	fi

	guard_target
}

guard_target() {
	_base=$(lower "$(basename_of "$TARGET")")
	for _d in $DENY_BASENAMES; do
		if [ "$_base" = "$_d" ]; then
			fail "refusing to write an always-loaded instruction file: $TARGET"
		fi
	done
	case $TARGET in
	*"$ARTIFACT"*) : ;;
	*) fail "refusing: install path does not name $ARTIFACT: $TARGET" ;;
	esac
	if [ -n "$OWNED_DIR" ] && [ "$OWNED_DIR" = "$SHARED_PARENT" ]; then
		OWNED_DIR=''
	fi
}

is_shared_parent() {
	_c=$1
	if [ "$_c" = "$SHARED_PARENT" ]; then
		return 0
	fi
	for _h in $HARNESS_LIST; do
		if [ "$_c" = "$(reroot "$(default_shared_parent "$_h")")" ]; then
			return 0
		fi
	done
	if [ "$_c" = "$(reroot "$(cfg_home)/opencode/command")" ]; then
		return 0
	fi
	return 1
}

opencode_rival() {
	reroot "$(cfg_home)/opencode/command/$ARTIFACT.md"
}

# -------------------------------------------------------------- actions ----

show_diff() {
	_old=$1
	_new=$2
	printf '%s\n' "--- $3 (current)"
	printf '%s\n' "+++ $3 (proposed)"
	if command -v diff >/dev/null 2>&1; then
		diff -u "$_old" "$_new" 2>/dev/null |
			awk 'NR <= 2 && (/^--- /  || /^\+\+\+ /) { next } { print }'
	else
		printf '(diff is not available; %s bytes would be written)\n' "$(wc -c <"$_new" | tr -d ' ')"
	fi
	return 0
}

ensure_dir() {
	if [ -d "$1" ]; then
		return 0
	fi
	_parent=$(dirname_of "$1")
	if [ "$_parent" != "$1" ] && [ ! -d "$_parent" ]; then
		ensure_dir "$_parent" || return 1
	fi
	mkdir "$1" 2>/dev/null || return 1
	chmod "$DIR_MODE" "$1" 2>/dev/null
	return 0
}

backup_path() {
	_base="$1.cosift-backup-$(date -u '+%Y%m%dT%H%M%SZ')"
	_try=$_base
	_n=2
	while [ -e "$_try" ]; do
		_try="$_base-$_n"
		_n=$((_n + 1))
	done
	printf '%s' "$_try"
}

same_file() {
	if [ ! -f "$1" ]; then
		return 1
	fi
	cmp -s "$1" "$2" 2>/dev/null
}

dir_has_other_entries() {
	for _e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
		if [ ! -e "$_e" ] && [ ! -L "$_e" ]; then
			continue
		fi
		if [ "$(basename_of "$_e")" = "$2" ]; then
			continue
		fi
		return 0
	done
	return 1
}

do_install() {
	if [ "$HARNESS" = opencode ]; then
		_rival=$(opencode_rival)
		if [ -e "$_rival" ]; then
			if [ "$FORCE" = 0 ]; then
				warn "refusing: $_rival already exists"
				warn "opencode scans both command/ and commands/, so installing ours would register /$ARTIFACT twice; remove that file or re-run with --force"
				if [ "$DRY_RUN" = 1 ]; then
					exit 0
				fi
				exit "$EX_FAIL"
			fi
			warn "warning: $_rival also defines /$ARTIFACT; --force given, continuing"
		fi
	fi

	if same_file "$TARGET" "$SOURCE"; then
		printf 'unchanged %s\n' "$TARGET"
		return 0
	fi

	_foreign=0
	if [ -e "$TARGET" ]; then
		_foreign=1
	fi

	if [ "$DRY_RUN" = 1 ]; then
		if [ "$_foreign" = 1 ]; then
			printf 'would replace %s\n' "$TARGET"
		else
			printf 'would install %s\n' "$TARGET"
		fi
		if [ -f "$TARGET" ]; then
			show_diff "$TARGET" "$SOURCE" "$TARGET"
		else
			show_diff /dev/null "$SOURCE" "$TARGET"
		fi
		if [ "$_foreign" = 1 ] && [ "$FORCE" = 0 ]; then
			printf 'would refuse: %s exists and differs; re-run with --force to back it up and replace it\n' "$TARGET"
		fi
		return 0
	fi

	if [ "$_foreign" = 1 ] && [ "$FORCE" = 0 ]; then
		warn "refusing: $TARGET already exists and is not the file we ship"
		warn "inspect it, then re-run with --force to back it up as <path>.cosift-backup-<UTC> and replace it"
		exit "$EX_FAIL"
	fi

	if ! ensure_dir "$TARGET_DIR"; then
		fail "cannot create directory: $TARGET_DIR"
	fi

	if [ "$_foreign" = 1 ]; then
		_bak=$(backup_path "$TARGET")
		if ! cp -p "$TARGET" "$_bak" 2>/dev/null; then
			if ! cp "$TARGET" "$_bak" 2>/dev/null; then
				fail "cannot create backup: $_bak"
			fi
		fi
		printf 'backed up %s -> %s\n' "$TARGET" "$_bak"
	fi

	TMPF="$TARGET_DIR/.$ARTIFACT.tmp.$$"
	if ! cp "$SOURCE" "$TMPF" 2>/dev/null; then
		rm -f "$TMPF" 2>/dev/null
		TMPF=''
		fail "cannot write into $TARGET_DIR"
	fi
	chmod "$FILE_MODE" "$TMPF" 2>/dev/null
	if ! mv "$TMPF" "$TARGET" 2>/dev/null; then
		rm -f "$TMPF" 2>/dev/null
		TMPF=''
		fail "cannot install $TARGET"
	fi
	TMPF=''

	if ! same_file "$TARGET" "$SOURCE"; then
		fail "post-install verification failed for $TARGET"
	fi
	printf 'installed %s\n' "$TARGET"
	return 0
}

do_uninstall() {
	_keep=0
	if [ ! -e "$TARGET" ]; then
		printf 'not installed %s\n' "$TARGET"
		_removable=0
	elif same_file "$TARGET" "$SOURCE"; then
		_removable=1
	elif grep -q "$ARTIFACT" "$TARGET" 2>/dev/null; then
		_removable=1
		_keep=1
	elif [ "$FORCE" = 1 ]; then
		_removable=1
		_keep=1
	else
		warn "refusing: $TARGET is not the file we ship (it was edited or belongs to something else)"
		warn "re-run with --force to remove it anyway"
		if [ "$DRY_RUN" = 1 ]; then
			exit 0
		fi
		exit "$EX_FAIL"
	fi

	if [ "$_removable" = 1 ] && [ "$DRY_RUN" = 1 ]; then
		if [ "$_keep" = 1 ]; then
			printf 'would back up %s -> %s\n' "$TARGET" "$TARGET.cosift-backup-<UTC>"
		fi
		printf 'would remove %s\n' "$TARGET"
	elif [ "$_removable" = 1 ]; then
		if [ "$_keep" = 1 ]; then
			_bak=$(backup_path "$TARGET")
			if ! cp -p "$TARGET" "$_bak" 2>/dev/null; then
				if ! cp "$TARGET" "$_bak" 2>/dev/null; then
					fail "cannot create backup: $_bak"
				fi
			fi
			printf 'backed up %s -> %s\n' "$TARGET" "$_bak"
		fi
		if ! rm -f "$TARGET" 2>/dev/null; then
			fail "cannot remove $TARGET"
		fi
		printf 'removed %s\n' "$TARGET"
	fi

	for _b in "$TARGET".cosift-backup-*; do
		if [ -e "$_b" ]; then
			printf 'left in place %s\n' "$_b"
		fi
	done

	if [ -z "$OWNED_DIR" ] || [ ! -d "$OWNED_DIR" ]; then
		return 0
	fi
	if [ "$(basename_of "$OWNED_DIR")" != "$ARTIFACT" ] || is_shared_parent "$OWNED_DIR"; then
		return 0
	fi
	if [ "$DRY_RUN" = 1 ]; then
		if ! dir_has_other_entries "$OWNED_DIR" "$(basename_of "$TARGET")"; then
			printf 'would remove directory %s\n' "$OWNED_DIR"
		fi
		return 0
	fi
	if rmdir "$OWNED_DIR" 2>/dev/null; then
		printf 'removed directory %s\n' "$OWNED_DIR"
	fi
	return 0
}

# ------------------------------------------------------------------ main --

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		--harness)
			[ $# -ge 2 ] || { warn "--harness needs a value"; exit "$EX_USAGE"; }
			HARNESS=$2
			shift
			;;
		--harness=*) HARNESS=${1#--harness=} ;;
		--dry-run) DRY_RUN=1 ;;
		--uninstall) UNINSTALL=1 ;;
		--force) FORCE=1 ;;
		--codex-skills-dir)
			[ $# -ge 2 ] || { warn "--codex-skills-dir needs a value"; exit "$EX_USAGE"; }
			CODEX_DIR=${2%/}
			shift
			;;
		--codex-skills-dir=*) CODEX_DIR=${1#--codex-skills-dir=} ;;
		--prefix)
			[ $# -ge 2 ] || { warn "--prefix needs a value"; exit "$EX_USAGE"; }
			PREFIX=$2
			shift
			;;
		--prefix=*) PREFIX=${1#--prefix=} ;;
		--manifest)
			[ $# -ge 2 ] || { warn "--manifest needs a value"; exit "$EX_USAGE"; }
			MANIFEST=$2
			shift
			;;
		--manifest=*) MANIFEST=${1#--manifest=} ;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			warn "unknown argument: $1"
			usage >&2
			exit "$EX_USAGE"
			;;
		esac
		shift
	done

	if [ -z "$HARNESS" ]; then
		warn 'missing --harness'
		usage >&2
		exit "$EX_USAGE"
	fi
	_known=0
	for _h in $HARNESS_LIST; do
		if [ "$_h" = "$HARNESS" ]; then
			_known=1
		fi
	done
	if [ "$_known" = 0 ]; then
		warn "unknown harness: $HARNESS (expected one of: $HARNESS_LIST)"
		exit "$EX_USAGE"
	fi
	if [ -z "$HOME" ] && [ -z "${XDG_CONFIG_HOME:-}" ]; then
		warn 'neither HOME nor XDG_CONFIG_HOME is set'
		exit "$EX_USAGE"
	fi
	if [ "$HARNESS" = hermes ]; then
		warn 'UNVERIFIED: the hermes install path has not been checked against a running hermes; verify it before relying on it'
	fi

	find_python || :
	plan

	if [ "$UNINSTALL" = 1 ]; then
		do_uninstall
	else
		do_install
	fi
}

main "$@"
