#!/bin/sh
# Tier B assertions. Runs INSIDE the container, against a throwaway HOME.
# Exit 0 = all observed assertions passed, 1 = at least one failed,
# 2 = preflight could not find a usable installer (nothing was proven).
set -u

ONBOARDING=${ONBOARDING_DIR:-/opt/onboarding}
FIXTURES=${FIXTURES_DIR:-/opt/fixtures}
WORK=${WORK_DIR:-/tmp/cosift-tierb}
TEMPLATE=${HOME_TEMPLATE:-/opt/cosift-test/home-template}
CLI_REPORT=${CLI_REPORT:-/opt/cosift-test/cli-report.tsv}
OC_PORT=${OC_PORT:-4096}
: "${XDG_CONFIG_HOME:=$HOME/.config}"
export XDG_CONFIG_HOME

ARTIFACT=cosift-onboarding
SENTINEL=COSIFT_TIER_B_SENTINEL
# Writes under the T3-owned state directory are reported, not counted as stray.
TOLERATE_RE='^\.config/cosift(/|$)'

n_pass=0
n_fail=0
n_skip=0
FORM=''
DRYRUN=no
SUPPORTED=''

pass() { n_pass=$((n_pass + 1)); printf 'PASS  %s\n' "$*"; }
fail() { n_fail=$((n_fail + 1)); printf 'FAIL  %s\n' "$*"; }
skip() { n_skip=$((n_skip + 1)); printf 'SKIP  %s\n' "$*"; }
note() { printf 'NOTE  %s\n' "$*"; }
section() { printf '\n===== %s\n' "$*"; }
indent() { sed 's/^/          /'; }

# ---------------------------------------------------------------- paths

target_path() {
    case "$1" in
    claude) printf '%s\n' "$HOME/.claude/skills/$ARTIFACT/SKILL.md" ;;
    codex) printf '%s\n' "$HOME/.agents/skills/$ARTIFACT/SKILL.md" ;;
    opencode) printf '%s\n' "$XDG_CONFIG_HOME/opencode/commands/$ARTIFACT.md" ;;
    hermes) printf '%s\n' "${HERMES_HOME:-$HOME/.hermes}/skills/$ARTIFACT/SKILL.md" ;;
    esac
}

# Directory uninstall is allowed to remove. Empty when the artifact is a bare file.
own_dir() {
    case "$1" in
    claude | codex | hermes) dirname "$(target_path "$1")" ;;
    opencode) printf '\n' ;;
    esac
}

shared_parent() {
    case "$1" in
    claude) printf '%s\n' "$HOME/.claude/skills" ;;
    codex) printf '%s\n' "$HOME/.agents/skills" ;;
    opencode) printf '%s\n' "$XDG_CONFIG_HOME/opencode/commands" ;;
    hermes) printf '%s\n' "${HERMES_HOME:-$HOME/.hermes}/skills" ;;
    esac
}

sibling_path() {
    case "$1" in
    opencode) printf '%s\n' "$(shared_parent "$1")/zz-neighbour.md" ;;
    *) printf '%s\n' "$(shared_parent "$1")/zz-neighbour/SKILL.md" ;;
    esac
}

rel() { printf '%s\n' "${1#"$HOME"/}"; }

# ---------------------------------------------------------------- HOME control

reset_home() {
    find "$HOME" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    cp -a "$TEMPLATE"/. "$HOME"/ 2>/dev/null
    mkdir -p "$XDG_CONFIG_HOME"
}

manifest() {
    (
        cd "$HOME" || exit 0
        find . -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r p; do
            q=${p#./}
            if [ -L "$p" ]; then
                printf 'l%s\t%s\t%s\n' "$(stat -c '%a' "$p")" "$(readlink "$p")" "$q"
            elif [ -d "$p" ]; then
                printf 'd%s\t-\t%s\n' "$(stat -c '%a' "$p")" "$q"
            elif [ -f "$p" ]; then
                printf 'f%s\t%s\t%s\n' "$(stat -c '%a' "$p")" "$(sha256sum "$p" | cut -d' ' -f1)" "$q"
            else
                printf 'o%s\t-\t%s\n' "$(stat -c '%a' "$p")" "$q"
            fi
        done
    )
}

changed_paths() {
    diff "$1" "$2" 2>/dev/null | sed -n 's/^[<>] //p' | cut -f3- | LC_ALL=C sort -u
}

ancestors_rel() {
    a_p=$1
    while :; do
        a_p=$(dirname "$a_p")
        case "$a_p" in . | / | '') break ;; esac
        printf '%s\n' "$a_p"
    done
}

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ---------------------------------------------------------------- installer adapter

inv() {
    i_h=$1
    shift
    case "$FORM" in
    harness-flag) timeout 120 sh "$INSTALLER" --harness "$i_h" "$@" </dev/null 2>&1 ;;
    positional) timeout 120 sh "$INSTALLER" "$i_h" "$@" </dev/null 2>&1 ;;
    only-flag) timeout 120 sh "$INSTALLER" --only "$i_h" "$@" </dev/null 2>&1 ;;
    dashdash) timeout 120 sh "$INSTALLER" "--$i_h" "$@" </dev/null 2>&1 ;;
    *) return 97 ;;
    esac
}

run_inv() {
    OUT=$(inv "$@")
    RC=$?
}

looks_unsupported() {
    printf '%s' "${1:-}" | grep -qiE 'unknown (option|flag|argument|harness)|unrecognized|invalid option|no such option'
}

detect_form() {
    for d_f in harness-flag positional only-flag dashdash; do
        for d_h in claude codex opencode hermes; do
            reset_home
            FORM=$d_f
            if inv "$d_h" --dry-run >/dev/null 2>&1; then
                DRYRUN=yes
                return 0
            fi
        done
    done
    for d_f in harness-flag positional only-flag dashdash; do
        for d_h in claude codex opencode hermes; do
            reset_home
            FORM=$d_f
            if inv "$d_h" >/dev/null 2>&1; then
                DRYRUN=no
                return 0
            fi
        done
    done
    FORM=''
    return 1
}

harness_supported() {
    reset_home
    if [ "$DRYRUN" = yes ]; then
        inv "$1" --dry-run >/dev/null 2>&1
    else
        inv "$1" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------- shared checks

# assert_no_stray <before> <after> <allowed-file> <label>
assert_no_stray() {
    changed_paths "$1" "$2" >"$WORK/changed"
    LC_ALL=C sort -u "$3" >"$WORK/allowed.sorted"
    comm -23 "$WORK/changed" "$WORK/allowed.sorted" | grep -Ev "$TOLERATE_RE" >"$WORK/stray" || true
    if grep -Eq "$TOLERATE_RE" "$WORK/changed"; then
        note "$4: installer also wrote the T3 state dir ($(grep -E "$TOLERATE_RE" "$WORK/changed" | tr '\n' ' '))"
    fi
    if [ -s "$WORK/stray" ]; then
        fail "$4  wrote paths outside the contract path"
        indent <"$WORK/stray"
        return 1
    fi
    return 0
}

check_frontmatter() {
    cf_h=$1
    cf_file=$2
    if ! python3 "$FIXTURES/frontmatter.py" "$cf_file" >"$WORK/fm" 2>"$WORK/fm.err"; then
        fail "frontmatter.$cf_h  frontmatter does not parse"
        indent <"$WORK/fm.err"
        return 1
    fi
    cut -f1 <"$WORK/fm" | LC_ALL=C sort -u >"$WORK/fm.keys"
    cf_keys=$(tr '\n' ' ' <"$WORK/fm.keys")
    case "$cf_h" in
    claude) cf_allowed='name description user-invocable disallowed-tools'; cf_required='name description' ;;
    codex) cf_allowed='name description'; cf_required='name description' ;;
    opencode) cf_allowed='description'; cf_required='description' ;;
    hermes) cf_allowed='name description version metadata'; cf_required='name description' ;;
    esac
    cf_bad=''
    for cf_k in $cf_keys; do
        case " $cf_allowed " in
        *" $cf_k "*) ;;
        *) cf_bad="$cf_bad $cf_k" ;;
        esac
    done
    cf_missing=''
    for cf_k in $cf_required; do
        case " $cf_keys " in
        *" $cf_k "*) ;;
        *) cf_missing="$cf_missing $cf_k" ;;
        esac
    done
    if [ -n "$cf_bad" ] || [ -n "$cf_missing" ]; then
        fail "frontmatter.$cf_h  keys [$cf_keys] violate the allowed set [$cf_allowed]"
        [ -n "$cf_bad" ] && printf 'disallowed keys:%s\n' "$cf_bad" | indent
        [ -n "$cf_missing" ] && printf 'missing keys:%s\n' "$cf_missing" | indent
        return 1
    fi
    cf_name=$(awk -F'\t' '$1=="name"{print $2}' "$WORK/fm")
    if [ -n "$cf_name" ] && [ "$cf_name" != "$ARTIFACT" ]; then
        fail "frontmatter.$cf_h  name is '$cf_name', expected '$ARTIFACT'"
        return 1
    fi
    if [ "$cf_h" = codex ]; then
        pass "frontmatter.codex  exactly name+description, nothing else"
    else
        pass "frontmatter.$cf_h  parses, keys [$cf_keys] within the allowed set"
    fi
    return 0
}

fm_value() {
    python3 "$FIXTURES/frontmatter.py" "$1" 2>/dev/null | awk -F'\t' -v k="$2" '$1==k{print $2}'
}

find_backups() {
    find "$HOME" -type f \( -name '*cosift-backup*' -o -name '*.bak' -o -name '*.orig' -o -name '*~' \) 2>/dev/null
}

# ---------------------------------------------------------------- test groups

t_clean_install() {
    ci_h=$1
    ci_t=$(target_path "$ci_h")
    reset_home
    manifest >"$WORK/before"
    run_inv "$ci_h"
    manifest >"$WORK/after"

    if [ "$RC" -ne 0 ]; then
        fail "install.$ci_h  installer exited $RC"
        printf '%s\n' "$OUT" | head -20 | indent
        return 1
    fi
    if [ ! -f "$ci_t" ]; then
        fail "install.$ci_h  contract path was not created: $ci_t"
        changed_paths "$WORK/before" "$WORK/after" | head -20 | indent
        return 1
    fi
    pass "install.$ci_h  wrote the contract path $(rel "$ci_t")"

    ci_mode=$(stat -c '%a' "$ci_t")
    if [ "$ci_mode" = 644 ]; then
        pass "mode.$ci_h  file is 0644"
    else
        fail "mode.$ci_h  file is 0$ci_mode, expected 0644"
    fi

    ci_dirbad=''
    for ci_d in $(ancestors_rel "$(rel "$ci_t")"); do
        ci_dm=$(stat -c '%a' "$HOME/$ci_d" 2>/dev/null)
        [ "$ci_dm" = 755 ] || ci_dirbad="$ci_dirbad $ci_d=0$ci_dm"
    done
    if [ -z "$ci_dirbad" ]; then
        pass "mode.$ci_h  every ancestor directory is 0755"
    else
        fail "mode.$ci_h  directory modes wrong:$ci_dirbad"
    fi

    : >"$WORK/allowed"
    rel "$ci_t" >>"$WORK/allowed"
    ancestors_rel "$(rel "$ci_t")" >>"$WORK/allowed"
    if assert_no_stray "$WORK/before" "$WORK/after" "$WORK/allowed" "isolation.$ci_h"; then
        pass "isolation.$ci_h  nothing else under HOME changed"
    fi

    if [ "$ci_h" = codex ]; then
        if [ -e "$HOME/.codex/skills/$ARTIFACT" ]; then
            fail "legacy-dir.codex  also installed into the legacy ~/.codex/skills"
        else
            pass "legacy-dir.codex  left the legacy ~/.codex/skills alone"
        fi
    fi

    check_frontmatter "$ci_h" "$ci_t"
}

t_codex_dir_override() {
    case " $SUPPORTED " in
    *" codex "*) ;;
    *)
        skip 'codex-dir-override  codex not supported by the installer'
        return 1
        ;;
    esac
    co_alt=$HOME/alt-skills
    reset_home
    run_inv codex --codex-skills-dir "$co_alt"
    if [ "$RC" -ne 0 ]; then
        if looks_unsupported "$OUT"; then
            skip 'codex-dir-override  installer has no --codex-skills-dir flag'
        else
            fail "codex-dir-override  exited $RC"
            printf '%s\n' "$OUT" | head -10 | indent
        fi
        return 1
    fi
    if [ -f "$co_alt/$ARTIFACT/SKILL.md" ] && [ ! -e "$HOME/.agents/skills/$ARTIFACT" ]; then
        pass 'codex-dir-override  --codex-skills-dir redirected the install, ~/.agents/skills untouched'
    else
        fail 'codex-dir-override  did not redirect the install'
        printf 'alt exists: %s   default exists: %s\n' \
            "$([ -f "$co_alt/$ARTIFACT/SKILL.md" ] && echo yes || echo no)" \
            "$([ -e "$HOME/.agents/skills/$ARTIFACT" ] && echo yes || echo no)" | indent
    fi
}

t_idempotent() {
    id_h=$1
    id_t=$(target_path "$id_h")
    reset_home
    run_inv "$id_h"
    [ "$RC" -eq 0 ] || {
        skip "idempotent.$id_h  first install failed ($RC)"
        return 1
    }
    manifest >"$WORK/first"
    id_sha1=$(sha_of "$id_t")
    run_inv "$id_h"
    id_rc2=$RC
    manifest >"$WORK/second"
    id_sha2=$(sha_of "$id_t")

    if [ "$id_rc2" -ne 0 ]; then
        fail "idempotent.$id_h  second install exited $id_rc2"
        printf '%s\n' "$OUT" | head -10 | indent
        return 1
    fi
    if [ "$id_sha1" != "$id_sha2" ]; then
        fail "idempotent.$id_h  second install changed the file bytes"
        return 1
    fi
    if ! diff -q "$WORK/first" "$WORK/second" >/dev/null 2>&1; then
        fail "idempotent.$id_h  second install changed HOME"
        changed_paths "$WORK/first" "$WORK/second" | head -10 | indent
        return 1
    fi
    if [ -n "$(find_backups)" ]; then
        fail "idempotent.$id_h  a backup was created with nothing to back up"
        find_backups | indent
        return 1
    fi
    pass "idempotent.$id_h  second install is byte-identical and creates no backup"
}

t_foreign() {
    fo_h=$1
    fo_t=$(target_path "$fo_h")
    reset_home
    mkdir -p "$(dirname "$fo_t")"
    printf '%s foreign file, not ours\n' "$SENTINEL" >"$fo_t"
    fo_sha=$(sha_of "$fo_t")
    manifest >"$WORK/before"
    run_inv "$fo_h"
    fo_rc=$RC
    fo_out=$OUT

    if [ "$fo_rc" -eq 0 ] && [ "$(sha_of "$fo_t")" != "$fo_sha" ]; then
        fail "foreign.$fo_h  a pre-existing foreign file was overwritten without --force"
        return 1
    fi
    if [ "$(sha_of "$fo_t")" != "$fo_sha" ]; then
        fail "foreign.$fo_h  foreign file changed even though the installer refused"
        return 1
    fi
    if [ "$fo_rc" -eq 0 ]; then
        fail "foreign.$fo_h  installer exited 0 on a foreign file (left it alone, but did not refuse)"
        printf '%s\n' "$fo_out" | head -10 | indent
    else
        pass "foreign.$fo_h  refused without --force (exit $fo_rc), foreign bytes intact"
    fi

    run_inv "$fo_h" --force
    if [ "$RC" -ne 0 ]; then
        if looks_unsupported "$OUT"; then
            skip "force.$fo_h  installer has no --force flag"
        else
            fail "force.$fo_h  --force exited $RC"
            printf '%s\n' "$OUT" | head -10 | indent
        fi
        return 1
    fi
    if [ "$(sha_of "$fo_t")" = "$fo_sha" ]; then
        fail "force.$fo_h  --force did not replace the foreign file"
        return 1
    fi
    manifest >"$WORK/after"
    fo_backup=''
    for fo_c in $(changed_paths "$WORK/before" "$WORK/after"); do
        [ -f "$HOME/$fo_c" ] || continue
        [ "$HOME/$fo_c" = "$fo_t" ] && continue
        if [ "$(sha_of "$HOME/$fo_c")" = "$fo_sha" ]; then
            fo_backup=$fo_c
            break
        fi
    done
    if [ -n "$fo_backup" ]; then
        pass "force.$fo_h  foreign bytes preserved in a backup at $fo_backup"
    else
        fail "force.$fo_h  --force replaced the file but no backup holds the foreign bytes"
        changed_paths "$WORK/before" "$WORK/after" | head -20 | indent
    fi
}

t_uninstall() {
    un_h=$1
    un_t=$(target_path "$un_h")
    un_own=$(own_dir "$un_h")
    un_parent=$(shared_parent "$un_h")
    un_sib=$(sibling_path "$un_h")

    reset_home
    mkdir -p "$(dirname "$un_sib")"
    printf -- '---\nname: zz-neighbour\ndescription: %s pre-seeded neighbour.\n---\n\nUnrelated.\n' "$SENTINEL" >"$un_sib"
    un_sibsha=$(sha_of "$un_sib")
    run_inv "$un_h"
    [ "$RC" -eq 0 ] && [ -f "$un_t" ] || {
        skip "uninstall.$un_h  install did not succeed, cannot test uninstall"
        return 1
    }

    run_inv "$un_h" --uninstall
    if [ "$RC" -ne 0 ]; then
        if looks_unsupported "$OUT"; then
            skip "uninstall.$un_h  installer has no --uninstall flag"
        else
            fail "uninstall.$un_h  --uninstall exited $RC"
            printf '%s\n' "$OUT" | head -10 | indent
        fi
        return 1
    fi

    un_bad=''
    [ -e "$un_t" ] && un_bad="$un_bad our-file-still-present"
    if [ -n "$un_own" ] && [ -e "$un_own" ]; then
        un_bad="$un_bad our-dir-still-present"
    fi
    [ -f "$un_sib" ] || un_bad="$un_bad sibling-deleted"
    [ "$(sha_of "$un_sib")" = "$un_sibsha" ] || un_bad="$un_bad sibling-modified"
    [ -d "$un_parent" ] || un_bad="$un_bad shared-parent-deleted"

    if [ -z "$un_bad" ]; then
        pass "uninstall.$un_h  removed our file$([ -n "$un_own" ] && printf ' and our own directory'), kept the neighbour and $(rel "$un_parent")"
    else
        fail "uninstall.$un_h $un_bad"
    fi
}

t_dry_run() {
    dr_h=$1
    dr_t=$(target_path "$dr_h")
    if [ "$DRYRUN" != yes ]; then
        skip "dryrun.$dr_h  installer has no --dry-run flag"
        return 1
    fi

    reset_home
    manifest >"$WORK/before"
    run_inv "$dr_h" --dry-run
    manifest >"$WORK/after"
    if [ "$RC" -ne 0 ]; then
        fail "dryrun.$dr_h  --dry-run on a clean HOME exited $RC"
        return 1
    fi
    if ! diff -q "$WORK/before" "$WORK/after" >/dev/null 2>&1; then
        fail "dryrun.$dr_h  --dry-run modified HOME"
        changed_paths "$WORK/before" "$WORK/after" | head -20 | indent
        return 1
    fi
    if [ -e "$dr_t" ]; then
        fail "dryrun.$dr_h  --dry-run created the contract path"
        return 1
    fi
    pass "dryrun.$dr_h  clean HOME: whole-HOME sha256 manifest unchanged"

    run_inv "$dr_h"
    [ "$RC" -eq 0 ] || return 1
    manifest >"$WORK/before"
    run_inv "$dr_h" --dry-run
    manifest >"$WORK/after"
    if diff -q "$WORK/before" "$WORK/after" >/dev/null 2>&1; then
        pass "dryrun.$dr_h  already-installed HOME: manifest unchanged"
    else
        fail "dryrun.$dr_h  --dry-run modified an already-installed HOME"
        changed_paths "$WORK/before" "$WORK/after" | head -20 | indent
    fi
}

t_opencode_duplicate_guard() {
    case " $SUPPORTED " in
    *" opencode "*) ;;
    *)
        skip "duplicate-guard.opencode  opencode not supported by the installer"
        return 1
        ;;
    esac
    dg_rival="$XDG_CONFIG_HOME/opencode/command/$ARTIFACT.md"
    reset_home
    mkdir -p "$(dirname "$dg_rival")"
    printf -- '---\ndescription: %s rival command.\n---\n\nRival.\n' "$SENTINEL" >"$dg_rival"
    dg_sha=$(sha_of "$dg_rival")
    run_inv opencode
    dg_rc=$RC
    dg_out=$OUT

    if [ "$(sha_of "$dg_rival")" != "$dg_sha" ]; then
        fail "duplicate-guard.opencode  the rival command/ file was modified"
        return 1
    fi
    dg_named=no
    printf '%s' "$dg_out" | grep -q 'command/' && dg_named=yes
    if [ "$dg_rc" -ne 0 ]; then
        if [ "$dg_named" = yes ]; then
            pass "duplicate-guard.opencode  refused (exit $dg_rc) and named the rival command/ path"
        else
            fail "duplicate-guard.opencode  refused (exit $dg_rc) but never named the rival command/ path"
            printf '%s\n' "$dg_out" | head -10 | indent
        fi
    elif [ "$dg_named" = yes ]; then
        pass "duplicate-guard.opencode  installed but loudly warned about the rival command/ path"
        printf '%s\n' "$dg_out" | grep 'command/' | head -3 | indent
    else
        fail "duplicate-guard.opencode  installed silently next to a rival command/$ARTIFACT.md"
        printf '%s\n' "$dg_out" | head -10 | indent
    fi
}

# The headline assertion: our artifact is the inverse of skillinject.
t_deny_list() {
    section 'HEADLINE: always-loaded instruction files are never touched'
    reset_home
    dl_files="$HOME/.claude/CLAUDE.md
$HOME/.codex/AGENTS.md
$XDG_CONFIG_HOME/opencode/AGENTS.md
${HERMES_HOME:-$HOME/.hermes}/SOUL.md
$HOME/AGENTS.md
$HOME/AGENTS.override.md"

    : >"$WORK/denylist.sha"
    printf '%s\n' "$dl_files" | while IFS= read -r dl_f; do
        mkdir -p "$(dirname "$dl_f")"
        printf '# %s\n\nOperator-owned instructions for %s.\nDo not rewrite this file.\n' \
            "$SENTINEL" "$(basename "$dl_f")" >"$dl_f"
        printf '%s\t%s\n' "$(sha_of "$dl_f")" "$dl_f" >>"$WORK/denylist.sha"
    done

    for dl_h in $SUPPORTED; do
        run_inv "$dl_h"
        [ "$RC" -eq 0 ] || note "deny-list: install of $dl_h exited $RC"
    done
    dl_bad=$(while IFS="$(printf '\t')" read -r dl_s dl_f; do
        [ "$(sha_of "$dl_f")" = "$dl_s" ] || printf '%s\n' "$dl_f"
    done <"$WORK/denylist.sha")
    if [ -z "$dl_bad" ]; then
        pass "denylist.install  CLAUDE.md, AGENTS.md, AGENTS.override.md and SOUL.md byte-identical after installing [$SUPPORTED]"
    else
        fail "denylist.install  an always-loaded instruction file changed"
        printf '%s\n' "$dl_bad" | indent
    fi

    for dl_h in $SUPPORTED; do
        run_inv "$dl_h" --uninstall
        [ "$RC" -eq 0 ] || note "deny-list: uninstall of $dl_h exited $RC"
    done
    dl_bad=$(while IFS="$(printf '\t')" read -r dl_s dl_f; do
        [ "$(sha_of "$dl_f")" = "$dl_s" ] || printf '%s\n' "$dl_f"
    done <"$WORK/denylist.sha")
    if [ -z "$dl_bad" ]; then
        pass "denylist.uninstall  the same four files byte-identical after uninstalling [$SUPPORTED]"
    else
        fail "denylist.uninstall  an always-loaded instruction file changed"
        printf '%s\n' "$dl_bad" | indent
    fi
}

# ---------------------------------------------------------------- discovery

oc_serve_stop() {
    [ -n "${OC_PID:-}" ] || return 0
    kill "$OC_PID" 2>/dev/null
    sleep 1
    kill -9 "$OC_PID" 2>/dev/null
    wait "$OC_PID" 2>/dev/null
    OC_PID=''
}

# oc_query <expected-name> -> writes probe output to $WORK/oc.out
oc_query() {
    (cd "$HOME" && OPENCODE_SERVER_PASSWORD='' timeout 120 opencode serve --pure \
        --port "$OC_PORT" --hostname 127.0.0.1 --print-logs >"$WORK/oc.log" 2>&1) &
    OC_PID=$!
    oq_i=0
    while [ "$oq_i" -lt 45 ]; do
        if node "$FIXTURES/oc-probe.js" "http://127.0.0.1:$OC_PORT/command" "$1" >"$WORK/oc.out" 2>&1; then
            oc_serve_stop
            return 0
        fi
        grep -q '^ERROR' "$WORK/oc.out" 2>/dev/null || {
            oc_serve_stop
            return 1
        }
        oq_i=$((oq_i + 1))
        sleep 1
    done
    oc_serve_stop
    return 2
}

t_discovery_opencode() {
    section 'DISCOVERY'
    case " $SUPPORTED " in
    *" opencode "*) ;;
    *)
        skip "discovery.opencode  opencode not supported by the installer"
        return 1
        ;;
    esac
    if ! grep -q '^real	opencode' "$CLI_REPORT" 2>/dev/null; then
        skip "discovery.opencode  the opencode CLI is a stub in this image"
        return 1
    fi

    do_t=$(target_path opencode)
    reset_home
    run_inv opencode
    [ "$RC" -eq 0 ] && [ -f "$do_t" ] || {
        skip "discovery.opencode  install did not succeed"
        return 1
    }
    do_desc=$(fm_value "$do_t" description)

    oc_query "$ARTIFACT"
    do_rc=$?
    if [ "$do_rc" -eq 2 ]; then
        fail "discovery.opencode  opencode serve never answered GET /command"
        tail -10 "$WORK/oc.log" 2>/dev/null | indent
        return 1
    fi
    if [ "$do_rc" -ne 0 ]; then
        fail "discovery.opencode  GET /command does not list $ARTIFACT"
        head -5 "$WORK/oc.out" | indent
        return 1
    fi
    do_src=$(awk -F'\t' '$1=="MATCH"{print $2; exit}' "$WORK/oc.out")
    do_got=$(awk -F'\t' '$1=="MATCH"{print $3; exit}' "$WORK/oc.out")
    if [ "$do_src" != command ]; then
        fail "discovery.opencode  listed, but source is '$do_src', expected 'command'"
        return 1
    fi
    pass "discovery.opencode  live GET /command lists '$ARTIFACT' (source=command)"
    if [ "$do_got" = "$do_desc" ]; then
        pass "discovery.opencode  served description matches the installed frontmatter"
    else
        fail "discovery.opencode  served description differs from the frontmatter"
        printf 'served:    %s\nfrontmatter: %s\n' "$do_got" "$do_desc" | indent
    fi
}

# codex renders the model-visible prompt offline, so the skill block it would
# actually send is directly observable without auth.
t_discovery_codex() {
    if ! grep -q '^real	codex' "$CLI_REPORT" 2>/dev/null; then
        skip 'discovery.codex  the codex CLI is a stub in this image'
        printf 'DISCOVERY: UNPROVEN (codex)\n'
        return 1
    fi
    case " $SUPPORTED " in
    *" codex "*) ;;
    *)
        skip 'discovery.codex  codex not supported by the installer'
        printf 'DISCOVERY: UNPROVEN (codex)\n'
        return 1
        ;;
    esac
    dc_t=$(target_path codex)
    reset_home
    run_inv codex
    [ "$RC" -eq 0 ] && [ -f "$dc_t" ] || {
        skip 'discovery.codex  install did not succeed'
        printf 'DISCOVERY: UNPROVEN (codex)\n'
        return 1
    }
    dc_desc=$(fm_value "$dc_t" description)
    mkdir -p "$HOME/work"
    (cd "$HOME/work" && git init -q . 2>/dev/null)
    (cd "$HOME/work" && timeout 90 codex debug prompt-input </dev/null 2>&1) >"$WORK/codex.out"
    if ! grep -q 'skills_instructions' "$WORK/codex.out"; then
        skip 'discovery.codex  codex debug prompt-input rendered no skills block'
        printf 'DISCOVERY: UNPROVEN (codex)\n'
        return 1
    fi
    if ! grep -q -- "- $ARTIFACT: $dc_desc" "$WORK/codex.out"; then
        fail "discovery.codex  the skills block does not list '$ARTIFACT' with its installed description"
        grep -o -- "- $ARTIFACT:[^\\\\]*" "$WORK/codex.out" | head -3 | indent
        return 1
    fi
    pass 'discovery.codex  codex debug prompt-input lists the skill with its installed description, no auth'
    if grep -q "$HOME/.agents/skills" "$WORK/codex.out"; then
        pass 'discovery.codex  codex resolves it from the ~/.agents/skills root'
    else
        fail 'discovery.codex  listed, but not from the ~/.agents/skills root'
        # shellcheck disable=SC2016
        grep -o '= `[^`]*skills[^`]*`' "$WORK/codex.out" | head -5 | indent
    fi
}

# Native, no-auth listing probes. Anything that does not genuinely list our
# artifact is reported UNPROVEN rather than downgraded to a weaker assertion.
t_discovery_native() {
    dn_h=$1
    shift
    if ! grep -q "^real	$dn_h" "$CLI_REPORT" 2>/dev/null; then
        skip "discovery.$dn_h  the $dn_h CLI is a stub in this image"
        printf 'DISCOVERY: UNPROVEN (%s)\n' "$dn_h"
        return 1
    fi
    case " $SUPPORTED " in
    *" $dn_h "*) ;;
    *)
        skip "discovery.$dn_h  $dn_h not supported by the installer"
        printf 'DISCOVERY: UNPROVEN (%s)\n' "$dn_h"
        return 1
        ;;
    esac
    reset_home
    run_inv "$dn_h"
    [ "$RC" -eq 0 ] || {
        skip "discovery.$dn_h  install did not succeed"
        printf 'DISCOVERY: UNPROVEN (%s)\n' "$dn_h"
        return 1
    }
    mkdir -p "$HOME/work"
    dn_found=''
    for dn_cmd in "$@"; do
        if (cd "$HOME/work" && eval "timeout 60 $dn_cmd" </dev/null 2>&1) |
            grep -q "$ARTIFACT"; then
            dn_found=$dn_cmd
            break
        fi
    done
    if [ -n "$dn_found" ]; then
        pass "discovery.$dn_h  '$dn_found' lists $ARTIFACT with no auth"
        return 0
    fi
    skip "discovery.$dn_h  no no-auth listing surface found (tried: $*)"
    printf 'DISCOVERY: UNPROVEN (%s)\n' "$dn_h"
    return 1
}

# Informational only: opencode also scans ~/.claude/skills and ~/.agents/skills,
# so it can read our claude/codex artifacts. That is a second reader agreeing on
# the path and the frontmatter, NOT native discovery by claude or codex.
t_cross_reader() {
    if ! grep -q '^real	opencode' "$CLI_REPORT" 2>/dev/null; then
        return 1
    fi
    cr_any=no
    for cr_h in claude codex; do
        case " $SUPPORTED " in
        *" $cr_h "*) ;;
        *) continue ;;
        esac
        reset_home
        run_inv "$cr_h"
        [ "$RC" -eq 0 ] || continue
        if oc_query "$ARTIFACT"; then
            cr_src=$(awk -F'\t' '$1=="MATCH"{print $2; exit}' "$WORK/oc.out")
            note "cross-reader: opencode's external-skill scan sees the $cr_h artifact (source=$cr_src). Informational, not native $cr_h discovery."
            cr_any=yes
        else
            note "cross-reader: opencode's external-skill scan does not see the $cr_h artifact."
        fi
    done
    [ "$cr_any" = yes ]
}

# ---------------------------------------------------------------- main

mkdir -p "$WORK"
[ -d "$TEMPLATE" ] || TEMPLATE=/tmp/cosift-home-template
mkdir -p "$TEMPLATE"
cp -a "$HOME"/. "$TEMPLATE"/ 2>/dev/null

printf 'Tier B: install mechanics at real production paths, throwaway HOME=%s\n' "$HOME"
printf 'XDG_CONFIG_HOME=%s\n' "$XDG_CONFIG_HOME"

INSTALLER=$(find "$ONBOARDING" -maxdepth 3 -type f -name 'install-onboarding.sh' 2>/dev/null | head -n 1)
if [ -z "$INSTALLER" ]; then
    INSTALLER=$(find "$ONBOARDING" -maxdepth 3 -type f -name 'install*.sh' 2>/dev/null | head -n 1)
fi
if [ -z "$INSTALLER" ]; then
    printf '\nSKIP-ALL  no installer found under %s (searched for install-onboarding.sh).\n' "$ONBOARDING"
    printf 'SKIP-ALL  Tier B proved NOTHING on this run.\n'
    exit 2
fi
printf 'installer=%s\n' "$INSTALLER"

if ! detect_form; then
    printf '\nSKIP-ALL  found %s but no invocation form worked.\n' "$INSTALLER"
    printf 'SKIP-ALL  tried: --harness H, positional H, --only H, --H (with and without --dry-run).\n'
    reset_home
    FORM=harness-flag
    printf 'SKIP-ALL  last output of "--harness claude --dry-run":\n'
    inv claude --dry-run 2>&1 | head -20 | indent
    printf 'SKIP-ALL  Tier B proved NOTHING on this run.\n'
    exit 2
fi
printf 'invocation form=%s   --dry-run supported=%s\n' "$FORM" "$DRYRUN"

for h in claude codex opencode hermes; do
    if harness_supported "$h"; then
        SUPPORTED="$SUPPORTED $h"
    else
        skip "harness.$h  the installer does not accept this harness"
    fi
done
SUPPORTED=$(printf '%s' "$SUPPORTED" | sed 's/^ *//')
printf 'harnesses supported by the installer: [%s]\n' "$SUPPORTED"
if [ -z "$SUPPORTED" ]; then
    printf '\nSKIP-ALL  the installer accepted no harness. Tier B proved NOTHING.\n'
    exit 2
fi

for h in claude codex opencode hermes; do
    case " $SUPPORTED " in *" $h "*) ;; *) continue ;; esac
    section "harness: $h"
    t_clean_install "$h"
    t_idempotent "$h"
    t_foreign "$h"
    t_uninstall "$h"
    t_dry_run "$h"
done

section 'codex skills-dir override'
t_codex_dir_override

section 'opencode duplicate-directory guard'
t_opencode_duplicate_guard

t_deny_list

t_discovery_opencode
t_discovery_native claude 'claude doctor' 'claude plugin list'
t_discovery_codex
t_cross_reader

reset_home

section 'SUMMARY'
printf 'pass=%d  fail=%d  skip=%d\n' "$n_pass" "$n_fail" "$n_skip"
if [ "$n_fail" -gt 0 ]; then
    printf 'RESULT: FAIL\n'
    exit 1
fi
if [ "$n_pass" -eq 0 ]; then
    printf 'RESULT: NOTHING PROVEN\n'
    exit 2
fi
printf 'RESULT: PASS\n'
exit 0
