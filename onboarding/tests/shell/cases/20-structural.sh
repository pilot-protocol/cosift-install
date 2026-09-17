#!/bin/sh
# Safety invariants over the whole onboarding/ tree.
set -u
# shellcheck disable=SC1091
. "$(dirname -- "$0")/00-lib.sh"

MANIFEST="$ONB_ROOT/generated/MANIFEST.json"

# Patterns keep their first character bracketed so this file never matches its own greps.
DENY_RE='[C]LAUDE\.md|[A]GENTS\.md|[A]GENTS\.override\.md|[S]OUL\.md'
Q='["'"'"']?'
CMDPOS='(^[[:space:]]*|[;|&(`{][[:space:]]*)((sudo|env|exec|command|then|do|else)[[:space:]]+)*'

REDIRECT_RE="(^|[^0-9A-Za-z_])>>?[[:space:]]*[^[:space:];|&]*($DENY_RE)"
DESTRUCTIVE_RE="$CMDPOS(rm|rmdir|touch|tee|sed|mkdir|truncate|dd)[[:space:]][^;|&]*($DENY_RE)"
COPY_RE="$CMDPOS(cp|mv|install|ln)[[:space:]][^;|&]*($DENY_RE)${Q}[[:space:]]*(\$|[;|&])"
PYWRITE_RE="(open|write_text|write_bytes|writelines|copyfile|copy2|symlink_to|unlink|makedirs)[[:space:]]*\([^)]*($DENY_RE)"
NETCMD_RE="$CMDPOS([c]url|[w]get|[n]c|[n]cat|[t]elnet|[f]tp|[s]cp|[s]ftp)[[:space:]]"
PYNET_RE='(^|[^A-Za-z0-9_])([i]mport|[f]rom)[[:space:]]+([u]rllib|[h]ttp|[s]ocket|[f]tplib|[t]elnetlib|[r]equests|[h]ttpx|[s]mtplib)'
URL_RE='[h]ttps?://'
URL_TOKEN_RE='[h]ttps?://[^[:space:]"`)]*'
LOOPBACK_RE='^[h]ttps?://(127\.0\.0\.1|localhost|0\.0\.0\.0|\[::1\])([:/]|$)'
COMMENT_HIT_RE='^[^:]*:[0-9]+:[[:space:]]*#'

# Everything shipped in bin/ counts, including the one script with no extension.
SHELL_FILES=$(find "$ONB_ROOT" -type f \( -name '*.sh' -o -path "$ONB_ROOT/bin/*" \) \
    ! -name '*.py' ! -name '*.md' ! -name '*.json' | LC_ALL=C sort -u)
PY_FILES=$(find "$ONB_ROOT" -type f -name '*.py' | LC_ALL=C sort)

if [ -z "$SHELL_FILES" ] && [ -z "$PY_FILES" ]; then
    skip_case "no shell or python files under onboarding/ yet"
fi

# --- the four always-loaded instruction files are never a write target -------------------

scan_write_targets() { # label files... ; reads the regexes from the enclosing scope
    _hits=""
    for _f in $2; do
        _found=$(grep -n -E "$1" "$_f" 2>/dev/null || true)
        if [ -n "$_found" ]; then
            _hits="$_hits
$_f: $_found"
        fi
    done
    printf '%s' "$_hits"
}

hits=$(scan_write_targets "$REDIRECT_RE" "$SHELL_FILES $PY_FILES")
assert_eq "" "$hits" "no script redirects into an always-loaded instruction file"

hits=$(scan_write_targets "$DESTRUCTIVE_RE" "$SHELL_FILES $PY_FILES")
assert_eq "" "$hits" "no script runs a destructive command against an always-loaded instruction file"

hits=$(scan_write_targets "$COPY_RE" "$SHELL_FILES $PY_FILES")
assert_eq "" "$hits" "no script copies or links onto an always-loaded instruction file"

hits=$(scan_write_targets "$PYWRITE_RE" "$PY_FILES")
assert_eq "" "$hits" "no python writer opens an always-loaded instruction file"

DATA_FILES=$(find "$ONB_ROOT/profiles" "$ONB_ROOT/generated" -type f -name '*.json' 2>/dev/null | LC_ALL=C sort)
hits=$(scan_write_targets "$DENY_RE" "$DATA_FILES")
assert_eq "" "$hits" "no profile or manifest names an always-loaded instruction file at all"

# --- no shipped script reaches the network -----------------------------------------------

hits=$(scan_write_targets "$NETCMD_RE" "$SHELL_FILES")
assert_eq "" "$hits" "no shell script invokes a network fetch command"

hits=$(scan_write_targets "$PYNET_RE" "$PY_FILES")
assert_eq "" "$hits" "no python file imports a network module"

url_lines=""
if [ -n "$SHELL_FILES" ]; then
    # shellcheck disable=SC2086
    url_lines=$(grep -n -H -E "$URL_RE" $SHELL_FILES 2>/dev/null || true)
fi
active_urls=$(printf '%s' "$url_lines" | grep -v -E "$COMMENT_HIT_RE" || true)
if [ -n "$active_urls" ]; then
    note "URLs on non-comment lines (loopback only is allowed):"
    printf '%s\n' "$active_urls" | while IFS= read -r line; do note "  $line"; done
fi
remote_urls=$(printf '%s' "$active_urls" | grep -o -E "$URL_TOKEN_RE" 2>/dev/null |
    grep -v -E "$LOOPBACK_RE" | LC_ALL=C sort -u || true)
assert_eq "" "$remote_urls" "no shell script names a remote URL outside a comment"

# --- the interview text hands out no URL and no pipe-to-shell ----------------------------
# The shipped .md files are what a model reads out to the user, so they are scanned too.
# A green "no script reaches the network" over an unscanned interview body would be the
# worst of both.

# WORDING.md is excluded on purpose: it is the lint ruleset, so its BANNED section has to
# spell out the very strings this scan forbids everywhere else.
SHIPPED_MD=$(find "$ONB_ROOT/interview" "$ONB_ROOT/generated" "$ONB_ROOT/docs" \
    -type f -name '*.md' ! -name 'WORDING.md' 2>/dev/null | LC_ALL=C sort)
if [ -z "$SHIPPED_MD" ]; then
    note "SKIPPED shipped-markdown scan: no .md under interview/, generated/ or docs/"
else
    # shellcheck disable=SC2086
    md_urls=$(grep -n -H -E "$URL_RE" $SHIPPED_MD 2>/dev/null |
        grep -o -E "$URL_TOKEN_RE" | grep -v -E "$LOOPBACK_RE" | LC_ALL=C sort -u || true)
    assert_eq "" "$md_urls" "no shipped markdown names a remote URL"

    PIPE_SHELL_RE='\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh|python3?)([[:space:]]|$)'
    # shellcheck disable=SC2086
    md_pipes=$(grep -n -H -E "$PIPE_SHELL_RE" $SHIPPED_MD 2>/dev/null || true)
    assert_eq "" "$md_pipes" "no shipped markdown pipes a download into a shell"

    # shellcheck disable=SC2086
    md_fetch=$(grep -n -H -E "$CMDPOS([c]url|[w]get)[[:space:]]" $SHIPPED_MD 2>/dev/null || true)
    assert_eq "" "$md_fetch" "no shipped markdown hands the user a fetch command"
fi

# --- the claude tool fence is exactly what the docs quote --------------------------------

CLAUDE_PROFILE="$ONB_ROOT/profiles/claude.json"
CLAUDE_GEN="$ONB_ROOT/generated/claude/cosift-onboarding/SKILL.md"
if [ ! -f "$CLAUDE_PROFILE" ] || [ ! -f "$CLAUDE_GEN" ]; then
    note "SKIPPED tool-fence checks: the claude profile or its generated file is missing"
else
    fence=$(python3 - "$CLAUDE_PROFILE" <<'PY'
import json, sys
for key, value in json.load(open(sys.argv[1]))["frontmatter"]:
    if key == "disallowed-tools":
        print(value)
        break
PY
)
    assert_eq "Read, Glob, Grep, Write, Edit, NotebookEdit, WebFetch, WebSearch, Task" "$fence" \
        "the claude profile fences the file and network tools by name"

    emitted=$(sed -n 's/^disallowed-tools: //p' "$CLAUDE_GEN")
    assert_eq "$fence" "$emitted" "the generated claude frontmatter carries that exact fence"

    # Bash is deliberately absent (the interview runs cosift-onboarding status), so both
    # user-facing docs have to quote the list rather than describe it.
    for doc in "$ONB_ROOT/docs/ONBOARDING.md" "$ONB_ROOT/docs/HARNESS-NOTES.md"; do
        if grep -F -q "disallowed-tools: $fence" "$doc"; then
            pass_note "$(basename "$doc") quotes the fence verbatim"
        else
            fail_note "$(basename "$doc") does not quote the emitted fence verbatim" \
                "expected a line: disallowed-tools: $fence"
        fi
        if grep -F -q 'Bash' "$doc"; then
            pass_note "$(basename "$doc") names Bash as the unfenced exception"
        else
            fail_note "$(basename "$doc") never mentions that Bash is left enabled"
        fi
    done
fi

# --- install paths are exactly the four contract paths ------------------------------------

if [ ! -f "$MANIFEST" ]; then
    note "SKIPPED manifest path checks: generated/MANIFEST.json is missing"
else
    # shellcheck disable=SC2016
    CONTRACT_PATHS='$HOME/.agents/skills/cosift-onboarding/SKILL.md
$HOME/.claude/skills/cosift-onboarding/SKILL.md
${HERMES_HOME:-$HOME/.hermes}/skills/cosift-onboarding/SKILL.md
${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands/cosift-onboarding.md'

    actual_paths=$(python3 - "$MANIFEST" <<'PY'
import json, sys
for entry in sorted(json.load(open(sys.argv[1]))["harnesses"], key=lambda e: e["install_path"]):
    print(entry["install_path"])
PY
)
    assert_eq "$CONTRACT_PATHS" "$actual_paths" "manifest install paths are exactly the four contract paths"

    mode_problems=$(python3 - "$MANIFEST" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
bad = []
for entry in manifest["harnesses"]:
    if entry["file_mode"] != "0644" or entry["dir_mode"] != "0755":
        bad.append(entry["harness"])
    install = entry["install_path"]
    shared = entry["shared_parent"]
    owned = entry["owned_dir"]
    if not install.startswith(shared + "/"):
        bad.append(entry["harness"] + ":shared_parent")
    if owned is not None and not owned.startswith(shared + "/"):
        bad.append(entry["harness"] + ":owned_dir")
    if owned is not None and install != owned + "/" + install.rsplit("/", 1)[-1]:
        bad.append(entry["harness"] + ":owned_dir_mismatch")
print(" ".join(bad))
PY
)
    assert_eq "" "$mode_problems" "manifest records 0644 files, 0755 dirs and consistent owned/shared dirs"
fi

# --- uninstall never removes a shared parent ----------------------------------------------

INSTALLER_FILES=$(find "$ONB_ROOT/bin" -type f ! -name '*.md' 2>/dev/null | LC_ALL=C sort)
if [ -z "$INSTALLER_FILES" ]; then
    note "SKIPPED installer checks: no scripts under onboarding/bin yet"
else
    bad_removals=""
    for f in $INSTALLER_FILES; do
        found=$(grep -n -E '(^|[^A-Za-z0-9_])(rm|rmdir)([[:space:]]|$)' "$f" 2>/dev/null |
            grep -E '(\.claude/skills|\.agents/skills|opencode/command|hermes\}?/skills)' |
            grep -v 'cosift-onboarding' || true)
        if [ -n "$found" ]; then
            bad_removals="$bad_removals
$f: $found"
        fi
    done
    assert_eq "" "$bad_removals" "no installer script removes a shared parent directory"

    # The file:line: prefix is stripped before matching, or the path of
    # install-onboarding.sh would itself match the command pattern.
    # shellcheck disable=SC2086
    bad_targets=$(grep -n -H -E '\.md' $INSTALLER_FILES 2>/dev/null |
        awk '{ body = $0; sub(/^[^:]*:[0-9]+:/, "", body)
               if (body ~ /(^|[^A-Za-z0-9_])(cp|mv|install|tee)[ \t]/ ||
                   body ~ />[ \t]*[^ \t]*\.md/) print }' |
        grep -v -E '(SKILL\.md|cosift-onboarding\.md|MANIFEST)' || true)
    assert_eq "" "$bad_targets" "installer file operations name only SKILL.md or cosift-onboarding.md"
fi

# --- every shell script parses -------------------------------------------------------------

syntax_bad=""
for f in $SHELL_FILES; do
    if ! out=$(sh -n "$f" 2>&1); then
        syntax_bad="$syntax_bad
$f: $out"
    fi
done
assert_eq "" "$syntax_bad" "sh -n passes on every shell script under onboarding/"

SHELLCHECK=${COSIFT_SHELLCHECK:-shellcheck}
if ! command -v "$SHELLCHECK" >/dev/null 2>&1 && [ -x "$ONB_ROOT/tests/shell/shellcheck-docker.sh" ] &&
    command -v docker >/dev/null 2>&1; then
    SHELLCHECK=$ONB_ROOT/tests/shell/shellcheck-docker.sh
fi
if command -v "$SHELLCHECK" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    if sc_out=$("$SHELLCHECK" -s sh $SHELL_FILES 2>&1); then
        pass_note "shellcheck -s sh is clean (via $SHELLCHECK)"
    else
        fail_note "shellcheck -s sh reported problems" "$sc_out"
    fi
else
    skip_note "shellcheck did not run: no '$SHELLCHECK' on PATH, and no docker for tests/shell/shellcheck-docker.sh" \
        "install shellcheck, or set COSIFT_SHELLCHECK to a shellcheck-compatible command" \
        "the POSIX-syntax invariant is therefore UNPROVEN on this run (sh -n still ran)"
fi

finish
