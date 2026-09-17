#!/bin/sh
# 40-status: bin/cosift-onboarding state detection and the complete write path.
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
BIN=$ONBOARDING/bin/cosift-onboarding

t_ok() { pass_note "$1"; }
t_bad() { fail_note "$1"; }
t_eq() { assert_eq "$3" "$2" "$1"; }

t_contains() {
	case $2 in
	*"$3"*) pass_note "$1" ;;
	*) fail_note "$1" "expected substring: $3" "actual: $2" ;;
	esac
}

WORK=$(mktemp -d) || exit 1
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP

OUT=''
RC=0
run() {
	OUT=$("$@" 2>"$WORK/stderr")
	RC=$?
	return 0
}

fresh() {
	_n=$((${_n:-0} + 1))
	XDG_CONFIG_HOME="$WORK/x$_n"
	export XDG_CONFIG_HOME
	mkdir -p "$XDG_CONFIG_HOME/cosift"
	STATE="$XDG_CONFIG_HOME/cosift/state.json"
	OWN="$XDG_CONFIG_HOME/cosift/onboarding.json"
}

mode_of() {
	stat -c '%a' "$1" 2>/dev/null ||
		stat -f '%Lp' "$1" 2>/dev/null ||
		printf 'no-stat'
}

backup_count() {
	_c=0
	for _f in "$1".cosift-backup-*; do
		[ -e "$_f" ] && _c=$((_c + 1))
	done
	printf '%s' "$_c"
}

seed_state() {
	cat >"$STATE" <<'EOF'
{
  "version": 1,
  "account_uid": "acct_2f9c",
  "harnesses_configured": ["claude", "opencode"],
  "onboarded": false,
  "installed_at": "2026-09-16T08:00:00Z",
  "zz_unknown": {"a": [1, 2, 3], "nested": {"deep": {"x": null, "y": true}}, "s": "keep \"me\""}
}
EOF
}

PY=''
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then
		PY=$c
		break
	fi
done

# --- absent state file ------------------------------------------------------
fresh
rm -rf "$XDG_CONFIG_HOME/cosift"
run "$BIN" status
t_eq 'absent: exit 2' "$RC" 2
t_eq 'absent: prints unknown' "$OUT" unknown
if [ -s "$WORK/stderr" ]; then
	t_ok 'absent: guidance on stderr'
else
	t_bad 'absent: expected one guidance line on stderr'
fi
t_eq 'absent: guidance is one line' "$(wc -l <"$WORK/stderr" | tr -d ' ')" 1

run "$BIN" status --json
t_eq 'absent: --json exit 2' "$RC" 2
t_contains 'absent: --json says present false' "$OUT" '"present":false'
t_eq 'absent: --json is one line' "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1

# --- pending / done / declined ---------------------------------------------
fresh
seed_state
run "$BIN" status
t_eq 'onboarded false: exit 0' "$RC" 0
t_eq 'onboarded false: prints pending' "$OUT" pending

printf '{"version":1,"onboarded":true}\n' >"$STATE"
run "$BIN" status
t_eq 'onboarded true: exit 1' "$RC" 1
t_eq 'onboarded true: prints done' "$OUT" 'done'

printf '{"version":1,"onboarded":"declined"}\n' >"$STATE"
run "$BIN" status
t_eq 'onboarded declined: exit 1' "$RC" 1
t_eq 'onboarded declined: prints declined' "$OUT" declined

# --- malformed --------------------------------------------------------------
fresh
printf '{ "version": 1, "onboarded": false,\n' >"$STATE"
before=$(cksum <"$STATE")
run "$BIN" status
t_eq 'malformed: status exit 3' "$RC" 3
t_eq 'malformed: prints malformed' "$OUT" malformed
t_contains 'malformed: path on stderr' "$(cat "$WORK/stderr")" "$STATE"
run "$BIN" complete
t_eq 'malformed: complete exit 3' "$RC" 3
t_eq 'malformed: file unchanged' "$(cksum <"$STATE")" "$before"
t_eq 'malformed: no backup written' "$(backup_count "$STATE")" 0

# --- complete over a real state file ----------------------------------------
fresh
seed_state
cp "$STATE" "$WORK/seed.json"
run "$BIN" complete
t_eq 'complete: exit 0' "$RC" 0
t_eq 'complete: mode 0600' "$(mode_of "$STATE")" 600
t_eq 'complete: one backup' "$(backup_count "$STATE")" 1
run "$BIN" status
t_eq 'complete: now done' "$OUT" 'done'

if [ -n "$PY" ]; then
	changed=$("$PY" - "$WORK/seed.json" "$STATE" <<'EOF'
import json, sys
missing = object()
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
keys = set(a) | set(b)
sys.stdout.write(','.join(sorted(k for k in keys if a.get(k, missing) != b.get(k, missing))))
EOF
	)
	t_eq 'complete: only the three onboarding keys changed' "$changed" 'onboarded,onboarded_at,onboarding_version'
	same=$("$PY" - "$WORK/seed.json" "$STATE" <<'EOF'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
same = json.dumps(a['zz_unknown'], sort_keys=True) == json.dumps(b['zz_unknown'], sort_keys=True)
sys.stdout.write('same' if same else 'differs')
EOF
	)
	t_eq 'complete: unknown key preserved intact' "$same" same
	run "$BIN" status --json
	parsed=$(printf '%s' "$OUT" | "$PY" -c 'import json,sys;d=json.load(sys.stdin);sys.stdout.write(str(d["onboarded"])+"|"+str(len(d["harnesses_configured"])))' 2>/dev/null)
	t_eq '--json parses and keeps harnesses_configured' "$parsed" 'True|2'
else
	t_ok 'complete: key-preservation checks skipped (no python)'
fi

# --- idempotent second complete --------------------------------------------
run "$BIN" complete
t_eq 'second complete: exit 0' "$RC" 0
t_contains 'second complete: reports already recorded' "$OUT" 'already recorded'
t_eq 'second complete: still one backup' "$(backup_count "$STATE")" 1

# --- declined ---------------------------------------------------------------
fresh
seed_state
run "$BIN" complete --declined
t_eq 'complete --declined: exit 0' "$RC" 0
run "$BIN" status
t_eq 'complete --declined: status declined' "$OUT" declined
t_eq 'complete --declined: exit 1' "$RC" 1

# --- absent state file: our own file, never a fake state.json ---------------
fresh
rm -rf "$XDG_CONFIG_HOME/cosift"
run "$BIN" complete
t_eq 'absent: complete exit 0' "$RC" 0
if [ -f "$OWN" ]; then
	t_ok 'absent: wrote onboarding.json'
else
	t_bad 'absent: expected onboarding.json'
fi
if [ -e "$STATE" ]; then
	t_bad 'absent: must not fabricate state.json'
else
	t_ok 'absent: did not fabricate state.json'
fi
t_eq 'absent: onboarding.json mode 0600' "$(mode_of "$OWN")" 600
t_eq 'absent: cosift dir mode 0700' "$(mode_of "$XDG_CONFIG_HOME/cosift")" 700
run "$BIN" status
t_eq 'absent: onboarding.json is authoritative' "$OUT" 'done'
t_eq 'absent: exit 1' "$RC" 1

printf '{"version":9,"onboarded":false}\n' >"$STATE"
run "$BIN" status
t_eq 'both files: state.json wins' "$OUT" pending

# --- usage ------------------------------------------------------------------
run "$BIN" status --nope
t_eq 'bad flag: exit 4' "$RC" 4
run "$BIN" nonsense
t_eq 'bad subcommand: exit 4' "$RC" 4

# --- paths ------------------------------------------------------------------
fresh
run "$BIN" paths
t_eq 'paths: exit 0' "$RC" 0
t_eq 'paths: four lines' "$(printf '%s\n' "$OUT" | grep -c .)" 4
t_contains 'paths: claude entry' "$OUT" '/.claude/skills/cosift-onboarding/SKILL.md'
t_contains 'paths: opencode entry' "$OUT" "$XDG_CONFIG_HOME/opencode/commands/cosift-onboarding.md"
run "$BIN" paths --json
t_eq 'paths --json: one line' "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1
if [ -n "$PY" ]; then
	got=$(printf '%s' "$OUT" | "$PY" -c 'import json,sys;sys.stdout.write(",".join(sorted(json.load(sys.stdin)["paths"])))' 2>/dev/null)
	t_eq 'paths --json: parses, four harnesses' "$got" 'claude,codex,hermes,opencode'
fi

# --- POSIX fallback ---------------------------------------------------------
COSIFT_ONBOARDING_NO_PYTHON=1
export COSIFT_ONBOARDING_NO_PYTHON

fresh
seed_state
run "$BIN" status
t_eq 'fallback: reads pending' "$OUT" pending
run "$BIN" complete
t_eq 'fallback: complete exit 0' "$RC" 0
t_eq 'fallback: one backup' "$(backup_count "$STATE")" 1
t_eq 'fallback: mode 0600' "$(mode_of "$STATE")" 600
run "$BIN" status
t_eq 'fallback: now done' "$OUT" 'done'
if [ -n "$PY" ]; then
	ok=$("$PY" - "$STATE" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
fine = (d['onboarded'] is True and d['account_uid'] == 'acct_2f9c'
        and d['zz_unknown']['nested']['deep']['y'] is True
        and 'onboarded_at' in d and 'onboarding_version' in d)
sys.stdout.write('yes' if fine else 'no')
EOF
	)
	t_eq 'fallback: result is valid JSON with unknown keys intact' "$ok" yes
fi

# complete writes onboarded_at, which contains the string "onboarded": counting the bare
# substring made the fallback refuse every run after the first.
fresh
seed_state
run "$BIN" complete
t_eq 'fallback: first complete' "$RC" 0
run "$BIN" complete --force
t_eq 'fallback: complete is repeatable once onboarded_at exists' "$RC" 0
run "$BIN" status
t_eq 'fallback: still done after the second complete' "$OUT" 'done'

# A key that merely starts with onboarded is not a second occurrence of the key.
fresh
printf '{\n  "onboarded": false,\n  "onboarded_elsewhere": "trap"\n}\n' >"$STATE"
run "$BIN" complete
t_eq 'fallback: a lookalike key is not a duplicate' "$RC" 0
t_eq 'fallback: the lookalike key is untouched' \
	"$(grep -c '"onboarded_elsewhere": "trap"' "$STATE")" 1

fresh
printf '{\n  "onboarded": false,\n  "zz": { "onboarded": true }\n}\n' >"$STATE"
before=$(cksum <"$STATE")
run "$BIN" complete
t_eq 'fallback: refuses a genuinely ambiguous file' "$RC" 3
t_eq 'fallback: refused write left the file alone' "$(cksum <"$STATE")" "$before"
t_eq 'fallback: refused write left no backup' "$(backup_count "$STATE")" 0

unset COSIFT_ONBOARDING_NO_PYTHON

finish
