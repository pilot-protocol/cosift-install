#!/bin/sh
# Assertion helpers dot-sourced by the tier-A cases. Not a case itself; run.sh skips it.

ONB_ROOT=${ONB_ROOT:-$(cd -- "$(dirname -- "$0")/../../.." && pwd)}
ONB_TMP=${ONB_TMP:-.}
export ONB_ROOT ONB_TMP

CHECKS=0
FAILURES=0
SKIPS=0

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

skip_note() { # label [detail...]
    SKIPS=$((SKIPS + 1))
    note "SKIP $1"
    shift
    for _detail in "$@"; do note "       $_detail"; done
    return 0
}

assert_true() { # status label [detail...]
    _st=$1
    shift
    if [ "$_st" -eq 0 ]; then pass_note "$1"; else fail_note "$@"; fi
}

assert_eq() { # expected actual label
    if [ "$1" = "$2" ]; then
        pass_note "$3"
    else
        fail_note "$3" "expected: $1" "actual:   $2"
    fi
}

assert_file() { # path label
    if [ -f "$1" ]; then pass_note "$2"; else fail_note "$2" "missing file: $1"; fi
}

assert_same_bytes() { # path-a path-b label
    if cmp -s -- "$1" "$2"; then
        pass_note "$3"
    else
        fail_note "$3" "differs: $1" "vs:      $2"
    fi
}

skip_case() { note "SKIP $*"; exit 77; }

finish() {
    if [ "$SKIPS" -gt 0 ]; then
        note "$SKIPS checks SKIPPED (see the SKIP lines above)"
    fi
    if [ "$FAILURES" -eq 0 ]; then
        note "$CHECKS checks passed"
        exit 0
    fi
    note "$FAILURES of $CHECKS checks failed"
    exit 1
}

sha256_of() { # path
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$1" | cut -d' ' -f1
    else
        python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
    fi
}

file_size() { wc -c <"$1" | tr -d ' \t'; }

# Frontmatter keys as emitted, in order: top-level "key:" lines between the first two "---".
frontmatter_keys() { # path
    awk '
        NR == 1 { if ($0 != "---") { exit 3 } ; next }
        $0 == "---" { exit 0 }
        /^[A-Za-z][A-Za-z0-9_-]*:/ { sub(/:.*$/, ""); print }
    ' "$1"
}

manifest_harnesses() { # manifest-path
    python3 - "$1" <<'PY'
import json, sys
print(" ".join(h["harness"] for h in json.load(open(sys.argv[1]))["harnesses"]))
PY
}

manifest_field() { # manifest-path harness key
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, harness, key = sys.argv[1], sys.argv[2], sys.argv[3]
for entry in json.load(open(path))["harnesses"]:
    if entry["harness"] == harness:
        value = entry[key]
        if isinstance(value, bool):
            print("true" if value else "false")
        elif isinstance(value, list):
            print(" ".join(str(item) for item in value))
        elif value is None:
            print("")
        else:
            print(value)
        break
else:
    sys.exit(1)
PY
}

manifest_top() { # manifest-path key
    python3 - "$1" "$2" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])
PY
}

profile_keys_sorted() { # profile-path key
    python3 - "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))[sys.argv[2]]
print(" ".join(sorted(value)) if isinstance(value, list) else str(value))
PY
}
