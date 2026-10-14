#!/bin/sh
# The generator takes the artifact as a parameter: --artifact selects one, an unknown name is refused.
set -u
# shellcheck disable=SC1091
. "$(dirname -- "$0")/00-lib.sh"

GENERATOR="$ONB_ROOT/tools/generate.py"
[ -f "$GENERATOR" ] || skip_case "tools/generate.py is missing"

python3 "$GENERATOR" --artifact cosift-onboarding --check >"$ONB_TMP/one.out" 2>&1
assert_true $? "--artifact cosift-onboarding --check exits 0" "$(cat "$ONB_TMP/one.out")"

python3 "$GENERATOR" --artifact no-such-artifact --check >"$ONB_TMP/bad.out" 2>&1
assert_eq "2" "$?" "an unknown artifact exits 2"
if grep -q 'unknown artifact' "$ONB_TMP/bad.out"; then
    pass_note "the refusal says the artifact is unknown"
else
    fail_note "the refusal does not say the artifact is unknown" "$(cat "$ONB_TMP/bad.out")"
fi

# The default check must fail when only an artifact other than the last one has drifted.
r="$ONB_TMP/drifted-first"
mkdir -p "$r"
cp -R "$ONB_ROOT/tools" "$ONB_ROOT/contribute" "$ONB_ROOT/VERSION" "$ONB_ROOT/profiles" \
    "$ONB_ROOT/interview" "$ONB_ROOT/generated" "$r/"
printf '\nAn extra line.\n' >>"$r/interview/BODY.md"
python3 "$r/tools/generate.py" --root "$r" --check >/dev/null 2>&1
assert_eq "1" "$?" "the default check fails when only the interview has drifted"

finish
