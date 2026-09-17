#!/usr/bin/env bash
# Container test matrix for the cosift T3 installer.
#
# Host mode:       tests/run.sh [-j N] [--no-build] [CASE_ID ...]
# Container mode:  tests/run.sh --container-case CASE_ID     (invoked by host mode)
#
# Written against the frozen installer contract only. It never reads install.sh.
set -uo pipefail

IMAGE="${COSIFT_TEST_IMAGE:-cosift-install-tests:latest}"
MOCK_PORT=8787
MOCK_LOG=/tmp/cosift-mock/requests.jsonl
AUTH_BASE="http://127.0.0.1:${MOCK_PORT}"
MCP_URL="http://127.0.0.1:${MOCK_PORT}/v1/mcp"
MINTED_TOKEN="ck_k1a_ABCDEFGHIJKLMNOPQRSTUVWXYZ234567ABCDEFG"
STALE_TOKEN="ck_old_QQQQQQQQQQQQQQQQQQQQQQQQQQ234567ZZZZZZZ"
EXTRA_HEADER_NAME="X-Cosift-Test"
EXTRA_HEADER_VALUE="probe-value-123"
CASE_TIMEOUT="${COSIFT_TEST_CASE_TIMEOUT:-420}"

# id|description|user
CASE_TABLE=(
  "C01|clean-install-all-three-harnesses|tester"
  "C02|second-run-is-a-noop-token-recovered|tester"
  "C03|dry-run-clean-box-changes-nothing|tester"
  "C04|dry-run-installed-box-changes-nothing|tester"
  "C05|preexisting-other-servers-survive|tester"
  "C06|refuse-malformed-claude-config|tester"
  "C07|refuse-malformed-codex-config|tester"
  "C08|refuse-foreign-codex-cosift-table|tester"
  "C09|refuse-malformed-opencode-config|tester"
  "C10|uninstall-then-reinstall|tester"
  "C11|no-tty-exits-6|tester"
  "C12|auth-five-wrong-codes-exhausted|tester"
  "C13|auth-503-retried-then-succeeds|tester"
  "C14|auth-banned-403-stops|tester"
  "C15|auth-429-rate-limited-reported|tester"
  "C16|mcp-401-and-421-distinct-messages|tester"
  "C17|opencode-torture-cosift-last|tester"
  "C18|opencode-torture-cosift-first|tester"
  "C19|opencode-torture-cosift-only|tester"
  "C20|opencode-uninstall-restores-backup|tester"
  "C21|extra-header-forwarded-and-persisted|tester"
  "C22|harness-subset-and-xdg-config-home|tester"
  "C23|cli-surface-help-version-unknown|tester"
  "C24|no-harness-detected-exits-3|root"
  "C25|preflight-missing-curl-exits-3|root"
  "C26|preflight-unwritable-home-exits-3|root"
  "C27|default-endpoints-use-production-cloud-run|tester"
  "C28|recovery-stale-token-falls-through|tester"
  "C29|token-never-leaks-outside-configs|tester"
  "C30|unparseable-claude-config-backed-up-before-cli|tester"
  "C31|codex-open-marker-without-close-refused|tester"
  "C32|codex-foreign-cosift-table-spellings|tester"
  "C33|malicious-extra-header-rejected|tester"
  "C34|claude-project-scope-entry-is-not-up-to-date|tester"
  "C35|uninstall-without-claude-binary-or-curl|root"
  "C36|token-bearing-configs-tightened-to-0600|tester"
  "C37|same-second-backups-are-not-lost|tester"
  "C38|uninstall-leaves-no-project-scoped-credential|tester"
  "C39|onboarding-clean-install-writes-three-artifacts|tester"
  "C40|onboarding-second-run-is-a-noop|tester"
  "C41|onboarding-dry-run-writes-nothing|tester"
  "C42|onboarding-uninstall-keeps-the-shared-dirs|tester"
  "C43|onboarding-never-touches-an-always-loaded-file|tester"
  "C44|onboarding-foreign-artifact-backed-up-first|tester"
  "C45|onboarding-declined-writes-nothing|tester"
  "C46|onboarding-harness-discovery|tester"
  "C47|onboarding-state-command-status-and-complete|tester"
  "C48|onboarding-never-writes-through-a-link|tester"
  "C49|uninstall-finds-artifacts-state-forgot|tester"
  "C50|claude-settings-merge-hook-and-permissions|tester"
  "C51|unparseable-settings-json-refused|tester"
  "C52|session-start-hook-command|tester"
  "C53|digest-titles-only-and-read-only|tester"
  "C54|colour-only-on-a-terminal|tester"
  "C55|no-claude-no-settings-json|tester"
  "C56|closing-launch-offer|tester"
  "C57|claude-reset-guard-discriminates|tester"
  "C58|new-account-never-reuses-a-credential|tester"
)

# =====================================================================
# container-side helpers
# =====================================================================

A_PASS=0
A_FAIL=0
A_SKIP=0

chk() { # chk <desc> <rc>
  if [ "$2" -eq 0 ]; then
    printf '    ok    %s\n' "$1"
    A_PASS=$((A_PASS + 1))
  else
    printf '    FAIL  %s\n' "$1"
    A_FAIL=$((A_FAIL + 1))
  fi
}

chk_eq() { # chk_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    chk "$1 (= $2)" 0
  else
    printf '    FAIL  %s: expected [%s] got [%s]\n' "$1" "$2" "$3"
    A_FAIL=$((A_FAIL + 1))
  fi
}

chk_contains() { # chk_contains <desc> <haystack> <needle>
  case "$2" in
    *"$3"*) chk "$1" 0 ;;
    *) printf '    FAIL  %s: missing [%s]\n' "$1" "$3"; A_FAIL=$((A_FAIL + 1)) ;;
  esac
}

chk_not_contains() {
  case "$2" in
    *"$3"*) printf '    FAIL  %s: unexpectedly contains [%s]\n' "$1" "$3"
            A_FAIL=$((A_FAIL + 1)) ;;
    *) chk "$1" 0 ;;
  esac
}

chk_matches() { # chk_matches <desc> <text> <ere>
  if printf '%s' "$2" | grep -Eqi "$3"; then
    chk "$1" 0
  else
    printf '    FAIL  %s: no match for /%s/\n' "$1" "$3"
    A_FAIL=$((A_FAIL + 1))
  fi
}

chk_file_mode() { # chk_file_mode <desc> <path> <mode>
  local m
  m=$(stat -c '%a' "$2" 2>/dev/null)
  chk_eq "$1" "$3" "${m:-MISSING}"
}

# a check that could not be made at all -- never counts as a pass
chk_skip() { # chk_skip <desc> [detail ...]
  printf '    SKIP  %s\n' "$1"
  shift
  local d
  for d in "$@"; do printf '          %s\n' "$d"; done
  A_SKIP=$((A_SKIP + 1))
}

chk_same_bytes() { # chk_same_bytes <desc> <path> <want-path>
  if [ ! -e "$2" ]; then
    printf '    FAIL  %s: missing %s\n' "$1" "$2"
    A_FAIL=$((A_FAIL + 1))
  elif cmp -s "$2" "$3"; then
    chk "$1" 0
  else
    printf '    FAIL  %s: %s differs from %s\n' "$1" "$2" "$3"
    A_FAIL=$((A_FAIL + 1))
  fi
}

chk_exists() { # chk_exists <desc> <path> <yes|no>
  chk_eq "$1" "$3" "$([ -e "$2" ] && echo yes || echo no)"
}

TH=/tmp/cosift-test/th.py
PTY=/tmp/cosift-test/ptydrive.py

write_helpers() {
  mkdir -p /tmp/cosift-test /tmp/cosift-mock
  cat >"$TH" <<'PYEOF'
import hashlib, json, os, re, stat, sys

try:
    import tomllib
except ImportError:
    tomllib = None


def manifest(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        links = [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]
        for d in links:
            p = os.path.join(dirpath, d)
            out.append("l %s -> %s" % (os.path.relpath(p, root), os.readlink(p)))
        dirnames[:] = sorted(d for d in dirnames if d not in links)
        filenames.sort()
        for name in [None] + filenames:
            p = dirpath if name is None else os.path.join(dirpath, name)
            rel = os.path.relpath(p, root)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            mode = stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                out.append("l %04o %s -> %s" % (mode, rel, os.readlink(p)))
            elif stat.S_ISDIR(st.st_mode):
                out.append("d %04o %s" % (mode, rel))
            elif stat.S_ISREG(st.st_mode):
                h = hashlib.sha256()
                with open(p, "rb") as fh:
                    for chunk in iter(lambda: fh.read(1 << 20), b""):
                        h.update(chunk)
                out.append("f %04o %s %s" % (mode, rel, h.hexdigest()))
            else:
                out.append("? %04o %s" % (mode, rel))
    print("\n".join(sorted(out)))


def _records(log):
    if not os.path.exists(log):
        return []
    rows = []
    with open(log, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    return rows


def _match(rows, method, path):
    return [
        r
        for r in rows
        if (method == "*" or r.get("method") == method)
        and r.get("path", "").split("?")[0].rstrip("/") == path.rstrip("/")
    ]


def count_req(log, method, path):
    print(len(_match(_records(log), method, path)))


def req_header(log, method, path, header):
    for r in _match(_records(log), method, path):
        print(r.get("headers", {}).get(header.lower(), ""))


def req_bodies(log, method, path):
    for r in _match(_records(log), method, path):
        print(json.dumps(r.get("body", "")))


def all_paths(log):
    for r in _records(log):
        print("%s %s %s" % (r.get("method"), r.get("path"), r.get("status")))


def state_check(path, csv_harnesses, version_hint, csv_onboarding="?"):
    probs = []
    if not os.path.exists(path):
        print("problem: state.json missing at %s" % path)
        return 1
    mode = stat.S_IMODE(os.lstat(path).st_mode)
    if mode != 0o600:
        probs.append("mode is %04o, want 0600" % mode)
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except ValueError as exc:
        print("problem: state.json is not valid JSON: %s" % exc)
        return 1
    want_keys = {
        "version",
        "account_uid",
        "harnesses_configured",
        "onboarded",
        "installed_at",
        "onboarding_installed",
        "onboarding_cmd",
    }
    got_keys = set(doc)
    if got_keys != want_keys:
        probs.append(
            "keys %s, want %s" % (sorted(got_keys), sorted(want_keys))
        )
    if not isinstance(doc.get("version"), str) or not doc.get("version"):
        probs.append("version must be a non-empty string")
    elif version_hint and doc["version"] not in version_hint:
        probs.append(
            "version %r not found in `--version` output %r"
            % (doc["version"], version_hint)
        )
    if not isinstance(doc.get("account_uid"), str):
        probs.append("account_uid must be a string")
    hs = doc.get("harnesses_configured")
    if not isinstance(hs, list) or not all(isinstance(x, str) for x in hs):
        probs.append("harnesses_configured must be a list of strings")
    else:
        want = set(x for x in csv_harnesses.split(",") if x)
        if set(hs) != want:
            probs.append("harnesses_configured %s, want %s" % (sorted(hs), sorted(want)))
    if doc.get("onboarded") is not False:
        probs.append("onboarded must be literal false")
    oi = doc.get("onboarding_installed")
    if not isinstance(oi, list) or not all(isinstance(x, str) for x in oi):
        probs.append("onboarding_installed must be a list of strings")
    else:
        if isinstance(hs, list) and not set(oi) <= set(hs):
            probs.append(
                "onboarding_installed %s is not a subset of harnesses_configured %s"
                % (sorted(oi), sorted(hs))
            )
        if csv_onboarding != "?":
            want = set(x for x in csv_onboarding.split(",") if x)
            if set(oi) != want:
                probs.append(
                    "onboarding_installed %s, want %s" % (sorted(oi), sorted(want))
                )
    oc = doc.get("onboarding_cmd")
    if not isinstance(oc, str):
        probs.append("onboarding_cmd must be a string")
    elif oi and not oc.endswith("/.local/bin/cosift-onboarding"):
        probs.append("onboarding_cmd %r is not the documented command path" % (oc,))
    ia = doc.get("installed_at")
    if not isinstance(ia, str) or not re.match(
        r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$", ia
    ):
        probs.append("installed_at %r is not RFC3339 UTC with a Z suffix" % (ia,))
    if probs:
        for p in probs:
            print("problem: %s" % p)
        return 1
    print("ok")
    return 0


def json_get(path, *keys):
    if not os.path.exists(path):
        print("NOFILE")
        return 0
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except ValueError:
        print("PARSE_ERROR")
        return 0
    for k in keys:
        if k not in doc:
            print("MISSING")
        elif isinstance(doc[k], str):
            print(doc[k])
        else:
            print(json.dumps(doc[k], sort_keys=True))
    return 0


def claude_entry(path, name):
    if not os.path.exists(path):
        print("NOFILE")
        return 0
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except ValueError:
        print("PARSE_ERROR")
        return 0
    top = (doc.get("mcpServers") or {}).get(name)
    scoped = [
        k
        for k, v in (doc.get("projects") or {}).items()
        if isinstance(v, dict) and name in (v.get("mcpServers") or {})
    ]
    print(json.dumps({"user_scope": top, "project_scopes": scoped}, sort_keys=True))
    return 0


def claude_names(path):
    if not os.path.exists(path):
        return 0
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except ValueError:
        print("PARSE_ERROR")
        return 0
    for n in sorted(doc.get("mcpServers") or {}):
        print(n)
    return 0


def toml_entry(path, name):
    if not os.path.exists(path):
        print("NOFILE")
        return 0
    if tomllib is None:
        print("NO_TOMLLIB")
        return 0
    try:
        with open(path, "rb") as fh:
            doc = tomllib.load(fh)
    except Exception:
        print("PARSE_ERROR")
        return 0
    e = (doc.get("mcp_servers") or {}).get(name)
    print(json.dumps(e, sort_keys=True) if e is not None else "ABSENT")
    return 0


def toml_names(path):
    if not os.path.exists(path) or tomllib is None:
        return 0
    try:
        with open(path, "rb") as fh:
            doc = tomllib.load(fh)
    except Exception:
        print("PARSE_ERROR")
        return 0
    for n in sorted(doc.get("mcp_servers") or {}):
        print(n)
    return 0


def _jsonc_strip(text):
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            if j >= n:
                raise ValueError("unterminated string")
            out.append(text[i : j + 1])
            i = j + 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            if j < 0:
                raise ValueError("unterminated block comment")
            i = j + 2
            continue
        out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def jsonc_entry(path, name):
    if not os.path.exists(path):
        print("NOFILE")
        return 0
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.loads(_jsonc_strip(fh.read()))
    except ValueError:
        print("PARSE_ERROR")
        return 0
    e = (doc.get("mcp") or {}).get(name)
    print(json.dumps(e, sort_keys=True) if e is not None else "ABSENT")
    return 0


def jsonc_names(path):
    if not os.path.exists(path):
        return 0
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.loads(_jsonc_strip(fh.read()))
    except ValueError:
        print("PARSE_ERROR")
        return 0
    for n in sorted(doc.get("mcp") or {}):
        print(n)
    return 0


def jsonc_valid(path):
    try:
        with open(path, encoding="utf-8") as fh:
            json.loads(_jsonc_strip(fh.read()))
    except Exception as exc:
        print("INVALID: %s" % exc)
        return 1
    print("VALID")
    return 0


def jsonc_topkeys(path):
    with open(path, encoding="utf-8") as fh:
        doc = json.loads(_jsonc_strip(fh.read()))
    for k in sorted(doc):
        print(k)
    return 0


def _load(path):
    if not os.path.exists(path):
        print("NOFILE")
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except ValueError:
        print("PARSE_ERROR")
        return None
    if not isinstance(doc, dict):
        print("NOT_AN_OBJECT")
        return None
    return doc


def _dig(doc, dotted):
    cur = doc
    for part in [p for p in dotted.split(".") if p]:
        if not isinstance(cur, dict) or part not in cur:
            return None, False
        cur = cur[part]
    return cur, True


def json_path(path, dotted=""):
    doc = _load(path)
    if doc is None:
        return 0
    val, ok = _dig(doc, dotted)
    print(json.dumps(val, sort_keys=True) if ok else "MISSING")
    return 0


def json_superset(path, dotted, want_path, want_dotted):
    doc = _load(path)
    want = _load(want_path)
    if doc is None or want is None:
        return 0
    have = _dig(doc, dotted)[0]
    need = _dig(want, want_dotted)[0]
    have = [json.dumps(x, sort_keys=True) for x in (have if isinstance(have, list) else [])]
    need = [json.dumps(x, sort_keys=True) for x in (need if isinstance(need, list) else [])]
    missing = [x for x in need if x not in have]
    print("SUPERSET" if not missing else "MISSING " + " | ".join(missing))
    return 0


def _walk_diff(a, b, path, out):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            if k not in b:
                out.append("extra %s.%s" % (path, k))
            elif k not in a:
                out.append("lost %s.%s" % (path, k))
            else:
                _walk_diff(a[k], b[k], "%s.%s" % (path, k), out)
    elif isinstance(a, list) and isinstance(b, list):
        for i in range(max(len(a), len(b))):
            if i >= len(b):
                out.append("extra %s[%d]=%s" % (path, i, json.dumps(a[i], sort_keys=True)))
            elif i >= len(a):
                out.append("lost %s[%d]=%s" % (path, i, json.dumps(b[i], sort_keys=True)))
            else:
                _walk_diff(a[i], b[i], "%s[%d]" % (path, i), out)
    elif a != b:
        out.append(
            "%s: %s != %s" % (path, json.dumps(a, sort_keys=True), json.dumps(b, sort_keys=True))
        )


def json_eq(path_a, path_b):
    a = _load(path_a)
    b = _load(path_b)
    if a is None or b is None:
        return 0
    out = []
    _walk_diff(a, b, "", out)
    print("SAME" if not out else "DIFF " + " ; ".join(out[:6]))
    return 0


def hook_cmds(path, event):
    doc = _load(path)
    if doc is None:
        return 0
    entries = (doc.get("hooks") or {}).get(event) or []
    for entry in entries if isinstance(entries, list) else []:
        if not isinstance(entry, dict):
            continue
        for h in entry.get("hooks") or []:
            if isinstance(h, dict):
                print(h.get("command", ""))
    return 0


def allow_list(path):
    doc = _load(path)
    if doc is None:
        return 0
    for e in (doc.get("permissions") or {}).get("allow") or []:
        print(e if isinstance(e, str) else json.dumps(e, sort_keys=True))
    return 0


CMDS = {
    "manifest": manifest,
    "count-req": count_req,
    "req-header": req_header,
    "req-bodies": req_bodies,
    "all-paths": all_paths,
    "state-check": state_check,
    "json-get": json_get,
    "claude-entry": claude_entry,
    "claude-names": claude_names,
    "toml-entry": toml_entry,
    "toml-names": toml_names,
    "jsonc-entry": jsonc_entry,
    "jsonc-names": jsonc_names,
    "jsonc-valid": jsonc_valid,
    "jsonc-topkeys": jsonc_topkeys,
    "json-path": json_path,
    "json-superset": json_superset,
    "json-eq": json_eq,
    "hook-cmds": hook_cmds,
    "allow-list": allow_list,
}

if __name__ == "__main__":
    fn = CMDS.get(sys.argv[1] if len(sys.argv) > 1 else "")
    if fn is None:
        sys.stderr.write("th.py: unknown command\n")
        sys.exit(2)
    sys.exit(fn(*sys.argv[2:]) or 0)
PYEOF

  cat >"$PTY" <<'PYEOF'
"""Run a command on a real pty and feed it scripted lines once output goes quiet.

The installer reads from /dev/tty, so a controlling terminal is mandatory; the
quiescence heuristic is what keeps input from being written before the prompt.
"""
import os, pty, select, signal, sys, time

lines_file, quiet_s, total_s = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
cmd = sys.argv[4:]
with open(lines_file, encoding="utf-8") as fh:
    lines = fh.read().splitlines()

pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
    os._exit(127)

buf = b""
sent = 0
last = time.time()
start = time.time()
timed_out = False
while True:
    if time.time() - start > total_s:
        timed_out = True
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        break
    try:
        r, _, _ = select.select([fd], [], [], 0.1)
    except OSError:
        break
    if r:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        buf += data
        last = time.time()
    elif sent < len(lines) and time.time() - last >= quiet_s:
        try:
            os.write(fd, lines[sent].encode() + b"\n")
        except OSError:
            break
        sent += 1
        last = time.time()

_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace").replace("\r\n", "\n").replace("\r", ""))
sys.stdout.flush()
sys.exit(124 if timed_out else os.waitstatus_to_exitcode(status))
PYEOF
}

MOCK_PID=""

mock_start() { # mock_start <scenario> [VAR=VAL ...]
  local scenario=$1
  shift
  mkdir -p /tmp/cosift-mock
  : >"$MOCK_LOG"
  env COSIFT_MOCK_SCENARIO="$scenario" \
      COSIFT_MOCK_LOG="$MOCK_LOG" \
      COSIFT_MOCK_PORT="$MOCK_PORT" \
      COSIFT_MOCK_VALID_TOKENS="$MINTED_TOKEN" \
      "$@" \
      python3 /work/tests/mock-endpoints.py >/tmp/cosift-mock/server.log 2>&1 &
  MOCK_PID=$!
  local i
  for i in $(seq 1 100); do
    if curl -fsS "$AUTH_BASE/health" >/dev/null 2>&1; then
      : >"$MOCK_LOG"   # drop our own readiness probe so counts are installer-only
      return 0
    fi
    sleep 0.1
  done
  echo "    (mock failed to start)" >&2
  cat /tmp/cosift-mock/server.log >&2
  return 1
}

mock_stop() {
  [ -n "$MOCK_PID" ] || return 0
  kill "$MOCK_PID" 2>/dev/null
  wait "$MOCK_PID" 2>/dev/null
  MOCK_PID=""
}

nreq() { python3 "$TH" count-req "$MOCK_LOG" "$1" "$2"; }

INSTALL_SH="${COSIFT_INSTALL_SH:-/work/install.sh}"
RC=0
OUT=""
STDOUT=""
STDERR=""
PTY_LINES=""

installer_env() {
  printf '%s\n' \
    "COSIFT_AUTH_BASE=$AUTH_BASE" \
    "COSIFT_MCP_URL=$MCP_URL"
}

# Runs the installer under a pty, feeding $PTY_LINES. INSTALL_MODE=piped uses the
# real `curl | sh` shape so a read from stdin instead of /dev/tty is caught.
install_pty() {
  local lf=/tmp/cosift-test/lines.txt
  if [ -n "$PTY_LINES" ]; then printf '%s\n' "$PTY_LINES" >"$lf"; else : >"$lf"; fi
  local inner
  if [ "${INSTALL_MODE:-direct}" = "piped" ]; then
    inner="cat $(printf '%q' "$INSTALL_SH") | sh -s --"
  else
    inner="sh $(printf '%q' "$INSTALL_SH")"
  fi
  local a
  for a in "$@"; do inner="$inner $(printf '%q' "$a")"; done
  local envp=(COSIFT_AUTH_BASE="$AUTH_BASE" COSIFT_MCP_URL="$MCP_URL")
  [ -n "${COSIFT_TEST_ALLOW_LAUNCH:-}" ] || envp+=(COSIFT_NO_LAUNCH=1)
  OUT=$(env "${envp[@]}" \
        python3 "$PTY" "$lf" 1.1 "${PTY_TOTAL:-150}" bash -c "$inner" 2>&1)
  RC=$?
}

install_notty() {
  local envp=(COSIFT_AUTH_BASE="$AUTH_BASE" COSIFT_MCP_URL="$MCP_URL")
  [ -n "${COSIFT_TEST_ALLOW_LAUNCH:-}" ] || envp+=(COSIFT_NO_LAUNCH=1)
  OUT=$(env "${envp[@]}" timeout 90 sh "$INSTALL_SH" "$@" </dev/null 2>&1)
  RC=$?
}

install_split() {
  local o e
  o=$(mktemp) && e=$(mktemp) || return 1
  COSIFT_AUTH_BASE="$AUTH_BASE" COSIFT_MCP_URL="$MCP_URL" \
    timeout 90 sh "$INSTALL_SH" "$@" >"$o" 2>"$e" </dev/null
  RC=$?
  STDOUT=$(cat "$o")
  STDERR=$(cat "$e")
  OUT="$STDOUT
$STDERR"
  rm -f "$o" "$e"
}

fixture() { # fixture <relpath-under-fixtures> <dest>
  mkdir -p "$(dirname "$2")"
  sed -e "s#__MCP_URL__#${MCP_URL}#g" \
      -e "s#__STALE_TOKEN__#${STALE_TOKEN}#g" \
      -e "s#__MINTED_TOKEN__#${MINTED_TOKEN}#g" \
      -e "s#__NOW_MS__#$(date +%s)000#g" \
      "/work/tests/fixtures/$1" >"$2"
}

manifest_of() { python3 "$TH" manifest "$HOME"; }

sha_of() { [ -f "${1:-}" ] && sha256sum "$1" | cut -d' ' -f1 || echo MISSING; }

backup_list() {
  find "$HOME" -name '*.cosift-backup-*' 2>/dev/null | sort
}

backups_wellformed() { # every backup name must match the documented pattern
  local bad=0 b
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    case "$(basename "$b")" in
      *.cosift-backup-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
      *) bad=1; printf '      bad backup name: %s\n' "$b" ;;
    esac
  done <<<"$(backup_list)"
  return $bad
}

OPENCODE_CFG=""
opencode_cfg() { # resolve whichever of .json/.jsonc opencode ended up using
  local base="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  if [ -f "$base/opencode.json" ]; then OPENCODE_CFG="$base/opencode.json"
  elif [ -f "$base/opencode.jsonc" ]; then OPENCODE_CFG="$base/opencode.jsonc"
  else OPENCODE_CFG="$base/opencode.json"; fi
  printf '%s\n' "$OPENCODE_CFG"
}

CLAUDE_CFG="" ; CODEX_CFG=""
set_paths() {
  CLAUDE_CFG="$HOME/.claude.json"
  CODEX_CFG="${CODEX_HOME:-$HOME/.codex}/config.toml"
  opencode_cfg >/dev/null
}

state_path() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/cosift/state.json"; }

installer_version() {
  timeout 30 sh "$INSTALL_SH" --version 2>/dev/null
}

# Assert the cosift entry landed at user scope in every named harness.
assert_installed() { # assert_installed <harness> ...
  local h e
  for h in "$@"; do
    case "$h" in
      claude)
        e=$(python3 "$TH" claude-entry "$CLAUDE_CFG" cosift)
        chk_not_contains "claude: entry is not project-scoped" "$e" '"project_scopes": ["'
        chk_contains "claude: user-scope entry present" "$e" "$MCP_URL"
        chk_contains "claude: entry type is http" "$e" '"type": "http"'
        chk_contains "claude: Authorization header written" "$e" "Bearer $MINTED_TOKEN"
        chk_contains "claude: cli lists cosift" \
          "$(timeout 60 claude mcp list 2>&1)" "cosift"
        ;;
      codex)
        e=$(python3 "$TH" toml-entry "$CODEX_CFG" cosift)
        chk_contains "codex: [mcp_servers.cosift] present and parseable" "$e" "$MCP_URL"
        chk_contains "codex: Authorization http_header written" "$e" \
          "Bearer $MINTED_TOKEN"
        chk_contains "codex: marker comment present" \
          "$(cat "$CODEX_CFG" 2>/dev/null)" ">>> cosift"
        chk_contains "codex: cli lists cosift" \
          "$(timeout 60 codex mcp list 2>&1)" "cosift"
        ;;
      opencode)
        opencode_cfg >/dev/null
        e=$(python3 "$TH" jsonc-entry "$OPENCODE_CFG" cosift)
        chk_contains "opencode: entry present" "$e" "$MCP_URL"
        chk_contains "opencode: entry type is remote" "$e" '"type": "remote"'
        chk_contains "opencode: Authorization header written" "$e" \
          "Bearer $MINTED_TOKEN"
        chk_contains "opencode: cli lists cosift" \
          "$(timeout 90 opencode mcp list 2>&1)" "cosift"
        ;;
    esac
  done
}

# a config file that never existed is as absent as an empty one
norm_absent() { case "$1" in NOFILE) echo ABSENT ;; *) echo "$1" ;; esac; }

assert_absent() { # assert_absent <harness> ...
  local h
  for h in "$@"; do
    case "$h" in
      claude)
        chk_eq "claude: cosift gone from user scope" 0 \
          "$(python3 "$TH" claude-names "$CLAUDE_CFG" | grep -c '^cosift$')"
        ;;
      codex)
        chk_eq "codex: cosift gone" "ABSENT" \
          "$(norm_absent "$(python3 "$TH" toml-entry "$CODEX_CFG" cosift)")"
        chk_not_contains "codex: markers gone" \
          "$(cat "$CODEX_CFG" 2>/dev/null)" ">>> cosift"
        ;;
      opencode)
        opencode_cfg >/dev/null
        chk_eq "opencode: cosift gone" "ABSENT" \
          "$(norm_absent "$(python3 "$TH" jsonc-entry "$OPENCODE_CFG" cosift)")"
        ;;
    esac
  done
}

seed_all_fixtures() {
  fixture claude/other-server.claude.json "$HOME/.claude.json"
  fixture codex/other-server.config.toml "$HOME/.codex/config.toml"
  fixture opencode/other-server.opencode.json \
    "$HOME/.config/opencode/opencode.json"
}

assert_others_survive() {
  chk_contains "claude: pre-existing 'weather' survives" \
    "$(python3 "$TH" claude-names "$CLAUDE_CFG")" "weather"
  chk_contains "claude: pre-existing 'notes' survives" \
    "$(python3 "$TH" claude-names "$CLAUDE_CFG")" "notes"
  chk_contains "codex: pre-existing 'weather' survives" \
    "$(python3 "$TH" toml-names "$CODEX_CFG")" "weather"
  chk_contains "codex: pre-existing 'notes' survives" \
    "$(python3 "$TH" toml-names "$CODEX_CFG")" "notes"
  opencode_cfg >/dev/null
  chk_contains "opencode: pre-existing 'weather' survives" \
    "$(python3 "$TH" jsonc-names "$OPENCODE_CFG")" "weather"
  chk_contains "opencode: comments survive" \
    "$(cat "$OPENCODE_CFG")" "KEEPME-TOP"
  chk_contains "opencode: block comment survives" \
    "$(cat "$OPENCODE_CFG")" "KEEPME-BLOCK"
}

EMAIL="tester+cosift@example.com"

# ---------------------------------------------------------------------
# onboarding interview artifacts
# ---------------------------------------------------------------------

ONB_GEN=/work/onboarding/generated
ONB_CMD_SRC=/work/onboarding/bin/cosift-onboarding

onb_artifact() { # onb_artifact <harness>
  case "$1" in
    claude)   printf '%s\n' "$HOME/.claude/skills/cosift-onboarding/SKILL.md" ;;
    codex)    printf '%s\n' \
                "${COSIFT_CODEX_SKILLS_DIR:-$HOME/.agents/skills}/cosift-onboarding/SKILL.md" ;;
    opencode) printf '%s\n' \
                "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands/cosift-onboarding.md" ;;
  esac
}

onb_source() { # the exact bytes that must land at onb_artifact <harness>
  case "$1" in
    claude)   printf '%s\n' "$ONB_GEN/claude/cosift-onboarding/SKILL.md" ;;
    codex)    printf '%s\n' "$ONB_GEN/codex/cosift-onboarding/SKILL.md" ;;
    opencode) printf '%s\n' "$ONB_GEN/opencode/cosift-onboarding.md" ;;
  esac
}

# empty for opencode: its file sits directly in the shared commands/ directory
onb_owned_dir() { # onb_owned_dir <harness>
  case "$1" in
    claude) printf '%s\n' "$HOME/.claude/skills/cosift-onboarding" ;;
    codex)  printf '%s\n' \
              "${COSIFT_CODEX_SKILLS_DIR:-$HOME/.agents/skills}/cosift-onboarding" ;;
  esac
}

onb_shared_parent() { # onb_shared_parent <harness>
  case "$1" in
    claude)   printf '%s\n' "$HOME/.claude/skills" ;;
    codex)    printf '%s\n' "${COSIFT_CODEX_SKILLS_DIR:-$HOME/.agents/skills}" ;;
    opencode) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands" ;;
  esac
}

onb_cmd() { printf '%s\n' "$HOME/.local/bin/cosift-onboarding"; }

onb_cmd_source() { printf '%s\n' "${ONB_GEN%/generated}/bin/cosift-onboarding"; }

onb_json() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/cosift/onboarding.json"; }

onb_backups() { # onb_backups <harness>
  local p
  p=$(onb_artifact "$1")
  find "${p%/*}" -name "${p##*/}.cosift-backup-*" 2>/dev/null | sort
}

assert_onboarding_installed() { # assert_onboarding_installed <harness> ...
  local h p d
  for h in "$@"; do
    p=$(onb_artifact "$h")
    chk_same_bytes "$h: artifact matches generated/$h byte for byte" "$p" "$(onb_source "$h")"
    chk_file_mode "$h: artifact is 0644" "$p" 644
    d=$(onb_owned_dir "$h")
    [ -n "$d" ] && chk_file_mode "$h: owned dir is 0755" "$d" 755
    chk_file_mode "$h: shared parent is 0755" "$(onb_shared_parent "$h")" 755
  done
}

assert_onboarding_absent() { # assert_onboarding_absent <harness> ...
  local h
  for h in "$@"; do
    chk_exists "$h: no artifact at $(onb_artifact "$h")" "$(onb_artifact "$h")" no
  done
}

assert_cmd_installed() {
  chk_same_bytes "state command is the shipped cosift-onboarding" \
    "$(onb_cmd)" "$ONB_CMD_SRC"
  chk_file_mode "state command is 0755" "$(onb_cmd)" 755
}

onb_is_stub() { # onb_is_stub <harness>
  local up
  up=$(printf '%s' "$1" | tr 'a-z' 'A-Z')
  grep -q "^${up}_PROVENANCE=stub$" /opt/cosift-test/harness-provenance.env 2>/dev/null
}

# ---------------------------------------------------------------------
# claude settings.json, the digest, and colour
# ---------------------------------------------------------------------

claude_settings() { printf '%s\n' "$HOME/.claude/settings.json"; }

settings_backups() {
  find "$HOME/.claude" -maxdepth 1 -name 'settings.json.cosift-backup-*' 2>/dev/null | sort
}

hook_cmds() { python3 "$TH" hook-cmds "$(claude_settings)" SessionStart; }

our_hook_cmd() { hook_cmds | grep 'cosift-onboarding' | head -1; }

count_lines() { printf '%s\n' "$1" | grep -c . || true; }

ESC=$(printf '\033')

has_colour() { printf '%s' "$1" | grep -q "$ESC\["; }

plain_text() { printf '%s\n' "$1" | LC_ALL=C sed -e "s/$ESC\[[0-9;?]*[A-Za-z]//g" \
    -e 's/\xe2\x9c\x93 *//g' -e 's/[[:space:]]*$//'; }

DIGEST_OUT="" ; DIGEST_ERR="" ; DIGEST_RC=0

digest_run() { # digest_run <home> [args ...]
  local h=$1 e=/tmp/cosift-test/digest-err.txt
  shift
  DIGEST_OUT=$(env HOME="$h" CODEX_HOME="$h/.codex" XDG_CONFIG_HOME="$h/.config" \
    timeout 60 sh "$ONB_CMD_SRC" digest "$@" 2>"$e")
  DIGEST_RC=$?
  DIGEST_ERR=$(cat "$e")
}

seed_digest_home() { # seed_digest_home <home>
  local h=$1 now i d
  now=$(date +%s)
  mkdir -p "$h/.claude/projects/newest" \
           "$h/.local/share/opencode/storage/session/default"
  printf '{"aiTitle":"Zephyr search relevance tuning","sessionId":"s00","type":"ai-title"}\n' \
    >"$h/.claude/projects/newest/s0.jsonl"
  touch -d "@$((now - 60))" "$h/.claude/projects/newest/s0.jsonl"
  i=1
  while [ "$i" -le 16 ]; do
    d="$h/.claude/projects/proj$i"
    mkdir -p "$d"
    printf '{"type":"user","message":{"role":"user","content":"unrelated turn"}}\n{"aiTitle":"Backlog grooming for service number %02d","sessionId":"s%02d","type":"ai-title"}\n' \
      "$i" "$i" >"$d/s$i.jsonl"
    touch -d "@$((now - 3600 - i * 600))" "$d/s$i.jsonl"
    i=$((i + 1))
  done
  fixture digest/claude-canary.jsonl "$h/.claude/projects/canary/c.jsonl"
  fixture digest/claude-path.jsonl "$h/.claude/projects/dirty/path.jsonl"
  fixture digest/claude-url.jsonl "$h/.claude/projects/dirty/url.jsonl"
  fixture digest/claude-email.jsonl "$h/.claude/projects/dirty/mail.jsonl"
  touch -d "@$((now - 7200))" "$h/.claude/projects/canary/c.jsonl" \
    "$h/.claude/projects/dirty/path.jsonl" "$h/.claude/projects/dirty/url.jsonl" \
    "$h/.claude/projects/dirty/mail.jsonl"
  fixture digest/claude-old.jsonl "$h/.claude/projects/old/old.jsonl"
  touch -d "@$((now - 200 * 86400))" "$h/.claude/projects/old/old.jsonl"
  fixture digest/opencode-legacy-session.json \
    "$h/.local/share/opencode/storage/session/default/ses_legacy.json"
}

seed_opencode_db() { # seed_opencode_db <path>
  python3 - "$1" <<'PYEOF'
import os, sqlite3, sys, time

path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
now = int(time.time() * 1000)
rows = [
    ("s1", "Sqlite index tuning for a catalogue", now - 86400000),
    ("s2", "Bluesky firehose backpressure", now - 2 * 86400000),
    ("s3", "Tidy up /var/tmp/OPENCODEDROPCANARY files", now - 3 * 86400000),
    ("s4", None, now),
]
con = sqlite3.connect(path)
con.execute(
    "create table session (id text primary key, title text, "
    "time_created integer, time_updated integer)"
)
con.executemany(
    "insert into session (id, title, time_created, time_updated) values (?,?,?,?)",
    [(i, t, c, c) for i, t, c in rows],
)
con.commit()
con.close()
PYEOF
}

# =====================================================================
# cases
# =====================================================================

case_C01() {
  mock_start ok || return 1
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  INSTALL_MODE=piped install_pty --yes
  chk_eq "exit code" 0 "$RC"
  set_paths
  assert_installed claude codex opencode

  local vers
  vers=$(installer_version)
  chk_eq "state.json shape/mode" "ok" \
    "$(python3 "$TH" state-check "$(state_path)" "claude,codex,opencode" "$vers" \
       "claude,codex,opencode")"
  chk_file_mode "state.json is 0600" "$(state_path)" 600

  chk_eq "exactly one /auth/start" 1 "$(nreq POST /auth/start)"
  chk_eq "exactly one /auth/verify" 1 "$(nreq POST /auth/verify)"
  chk_eq "never probed /healthz" 0 "$(nreq '*' /healthz)"
  local mcpauth
  mcpauth=$(python3 "$TH" req-header "$MOCK_LOG" POST /v1/mcp authorization | sort -u)
  chk_contains "MCP initialize carried the bearer token" "$mcpauth" \
    "Bearer $MINTED_TOKEN"
  chk_contains "MCP initialize used method=initialize" \
    "$(python3 "$TH" req-bodies "$MOCK_LOG" POST /v1/mcp)" "initialize"
  chk_eq "no 406/415 from the mock (Accept/Content-Type correct)" "" \
    "$(python3 "$TH" all-paths "$MOCK_LOG" | grep -E ' (406|415)$' || true)"
  chk_not_contains "token not printed in full" "$OUT" "$MINTED_TOKEN"
  chk_contains "summary mentions revocation" "$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')" "revoke"
  mock_stop
}

case_C02() {
  mock_start ok || return 1
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "first run exit code" 0 "$RC"
  set_paths
  local b1 m1
  b1=$(backup_list | wc -l)
  m1=$(manifest_of)

  PTY_LINES=""
  install_notty --yes
  chk_eq "second run exit code" 0 "$RC"
  chk_eq "no second /auth/start (token was recovered)" 1 "$(nreq POST /auth/start)"
  chk_eq "no second /auth/verify" 1 "$(nreq POST /auth/verify)"
  chk_eq "backup count unchanged by the no-op run" "$b1" "$(backup_list | wc -l)"
  chk_eq "claude has exactly one cosift entry" 1 \
    "$(python3 "$TH" claude-names "$CLAUDE_CFG" | grep -c '^cosift$')"
  chk_eq "codex config has exactly one marker block" 1 \
    "$(grep -c '>>> cosift' "$CODEX_CFG" 2>/dev/null || echo 0)"
  opencode_cfg >/dev/null
  chk_eq "opencode has exactly one cosift key" 1 \
    "$(python3 "$TH" jsonc-names "$OPENCODE_CFG" | grep -c '^cosift$')"
  assert_installed claude codex opencode
  mock_stop
}

case_C03() {
  mock_start ok || return 1
  seed_all_fixtures
  set_paths
  cd "$HOME" || return 1
  local before after
  before=$(manifest_of)
  install_notty --dry-run --yes
  chk_eq "exit code" 0 "$RC"
  after=$(manifest_of)
  chk_eq "\$HOME is byte-identical after --dry-run" "" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -40)"
  chk_eq "dry-run never started the email flow" 0 "$(nreq POST /auth/start)"
  chk_eq "dry-run never minted a token" 0 "$(nreq POST /auth/verify)"
  chk_contains "plan names claude" "$OUT" "claude"
  chk_contains "plan names codex" "$OUT" "codex"
  chk_contains "plan names opencode" "$OUT" "opencode"
  chk_eq "no state dir created" "no" \
    "$([ -e "${XDG_CONFIG_HOME:-$HOME/.config}/cosift" ] && echo yes || echo no)"
  chk_eq "no backups created" 0 "$(backup_list | wc -l)"
  mock_stop
}

case_C04() {
  mock_start ok || return 1
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "install exit code" 0 "$RC"
  set_paths
  local before after
  before=$(manifest_of)
  PTY_LINES=""
  install_notty --dry-run --yes
  chk_eq "dry-run exit code" 0 "$RC"
  after=$(manifest_of)
  chk_eq "\$HOME is byte-identical after --dry-run on an installed box" "" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -40)"
  chk_eq "dry-run did not re-run the email flow" 1 "$(nreq POST /auth/start)"
  mock_stop
}

case_C05() {
  mock_start ok || return 1
  seed_all_fixtures
  set_paths
  local claude_before codex_before oc_before
  claude_before=$(sha_of "$CLAUDE_CFG")
  codex_before=$(sha_of "$CODEX_CFG")
  oc_before=$(sha_of "$OPENCODE_CFG")
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "install exit code" 0 "$RC"
  assert_installed claude codex opencode
  assert_others_survive
  backups_wellformed
  chk "every backup name matches <path>.cosift-backup-<UTC>" $?
  chk_contains "claude config was backed up" "$(backup_list)" ".claude.json.cosift-backup-"
  chk_contains "codex config was backed up" "$(backup_list)" "config.toml.cosift-backup-"
  chk_contains "opencode config was backed up" "$(backup_list)" "opencode.json.cosift-backup-"
  chk_eq "claude backup is the original bytes" "$claude_before" \
    "$(sha_of "$(backup_list | grep '\.claude\.json\.cosift-backup-' | head -1)")"
  chk_eq "codex backup is the original bytes" "$codex_before" \
    "$(sha_of "$(backup_list | grep 'config\.toml\.cosift-backup-' | head -1)")"
  chk_eq "opencode backup is the original bytes" "$oc_before" \
    "$(sha_of "$(backup_list | grep 'opencode\.json\.cosift-backup-' | head -1)")"

  PTY_LINES=""
  install_notty --uninstall
  chk_eq "uninstall exit code" 0 "$RC"
  assert_absent claude codex opencode
  assert_others_survive
  mock_stop
}

refuse_case() { # refuse_case <fixture> <dest> <harness-list>
  mock_start ok || return 1
  fixture "$1" "$2"
  set_paths
  local before
  before=$(sha_of "$2")
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  # no --yes: the consent prompt comes at harness selection, before the email
  PTY_LINES="y
$EMAIL
123456"
  install_pty "--harness=$3"
  chk_eq "exit code is 5 (refusal)" 5 "$RC"
  chk_eq "the config we refused is byte-identical" "$before" "$(sha_of "$2")"
  chk_not_contains "token not printed in full" "$OUT" "$MINTED_TOKEN"
  mock_stop
}

case_C06() {
  refuse_case claude/malformed.claude.json "$HOME/.claude.json" claude
  chk_eq "claude did not quarantine-and-reset the file" "PARSE_ERROR" \
    "$(python3 "$TH" claude-entry "$HOME/.claude.json" cosift)"
}

case_C07() { refuse_case codex/malformed.config.toml "$HOME/.codex/config.toml" codex; }

case_C08() {
  refuse_case codex/foreign-cosift.config.toml "$HOME/.codex/config.toml" codex
  chk_not_contains "no marker block was appended" \
    "$(cat "$HOME/.codex/config.toml")" ">>> cosift"
}

case_C09() {
  refuse_case opencode/malformed.opencode.json \
    "$HOME/.config/opencode/opencode.json" opencode
}

case_C10() {
  mock_start ok || return 1
  seed_all_fixtures
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "install exit code" 0 "$RC"
  local backups_before
  backups_before=$(backup_list | wc -l)

  # state.json is removed first so the documented "fall back to detection" path runs
  rm -f "$(state_path)"
  PTY_LINES=""
  install_notty --uninstall
  chk_eq "uninstall exit code (state.json missing)" 0 "$RC"
  assert_absent claude codex opencode
  assert_others_survive
  chk_eq "state.json gone" "no" "$([ -e "$(state_path)" ] && echo yes || echo no)"
  chk "backups left in place" \
    "$([ "$(backup_list | wc -l)" -ge "$backups_before" ] && echo 0 || echo 1)"

  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "re-install after uninstall exit code" 0 "$RC"
  assert_installed claude codex opencode
  assert_others_survive
  mock_stop
}

case_C11() {
  mock_start ok || return 1
  cd "$HOME" || return 1
  local before after
  before=$(manifest_of)
  install_notty            # no --yes, no --harness, stdin is /dev/null, no pty
  chk_eq "exit code is 6 (no usable /dev/tty)" 6 "$RC"
  after=$(manifest_of)
  chk_eq "no partial writes to \$HOME" "" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -40)"
  chk_contains "tells the user to download and run directly" \
    "$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')" "download"
  chk_eq "no auth traffic" 0 "$(nreq POST /auth/start)"
  mock_stop
}

case_C12() {
  mock_start wrongcode || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
111111
222222
333333
444444
555555
666666"
  PTY_TOTAL=120 install_pty --yes
  chk_eq "exit code is 4 (authentication failure)" 4 "$RC"
  chk_eq "stopped after exactly 5 verify attempts" 5 "$(nreq POST /auth/verify)"
  chk_contains "copy says wrong and expired are indistinguishable" \
    "$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')" "expired"
  chk_matches "copy explains the 3-codes-per-address-per-hour cap" "$OUT" \
    "3 codes|3 per hour|per address per hour|three codes"
  assert_absent claude codex opencode
  mock_stop
}

case_C13() {
  mock_start unavailable COSIFT_MOCK_FAIL_N=2 || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456
123456
123456"
  PTY_TOTAL=120 install_pty --yes
  chk_eq "exit code 0 after retrying through 503" 0 "$RC"
  chk "verify was retried at least 3 times" \
    "$([ "$(nreq POST /auth/verify)" -ge 3 ] && echo 0 || echo 1)"
  assert_installed claude codex opencode
  mock_stop
}

case_C14() {
  mock_start banned || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456
123456
123456"
  install_pty --yes
  chk_eq "exit code is 4" 4 "$RC"
  chk_eq "stopped immediately: exactly one verify call" 1 "$(nreq POST /auth/verify)"
  assert_absent claude codex opencode
  mock_stop
}

case_C15() {
  mock_start ratelimited || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk "exit code is non-zero" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
  chk_contains "reports the rate limit to the user" \
    "$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')" "rate"
  assert_absent claude codex opencode
  mock_stop
}

case_C16() {
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  mock_start mcp401 || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  local rc401="$RC" out401="$OUT"
  chk "mcp 401: non-zero exit" "$([ "$rc401" -ne 0 ] && echo 0 || echo 1)"
  mock_stop

  rm -rf "$HOME/.claude.json" "$HOME/.codex" "$HOME/.config" "$HOME/.local"
  mock_start mcp421 || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  local rc421="$RC" out421="$OUT"
  chk "mcp 421: non-zero exit" "$([ "$rc421" -ne 0 ] && echo 0 || echo 1)"
  mock_stop

  local n401 n421
  n401=$(printf '%s' "$out401" | tr 'A-Z' 'a-z' | grep -c 'invalid_token\|token' || true)
  n421=$(printf '%s' "$out421" | tr 'A-Z' 'a-z' \
         | grep -c 'host\|421\|rebind\|allowed' || true)
  chk "401 message talks about the token" "$([ "$n401" -gt 0 ] && echo 0 || echo 1)"
  chk "421 message talks about the hostname" "$([ "$n421" -gt 0 ] && echo 0 || echo 1)"
  chk "401 and 421 produce different messages" \
    "$([ "$out401" != "$out421" ] && echo 0 || echo 1)"
  chk_not_contains "421 message does not blame the token" \
    "$(printf '%s' "$out421" | tr 'A-Z' 'a-z')" "invalid_token"
}

opencode_torture() { # opencode_torture <fixture> <expect-weather:yes|no>
  mock_start ok || return 1
  local cfg="$HOME/.config/opencode/opencode.json"
  fixture "opencode/$1" "$cfg"
  set_paths
  local before
  before=$(cat "$cfg")
  cd "$HOME" || return 1
  install_notty --uninstall --harness=opencode
  chk_eq "uninstall exit code" 0 "$RC"
  chk_eq "cosift key removed" "ABSENT" "$(python3 "$TH" jsonc-entry "$cfg" cosift)"
  chk_eq "file still parses as JSONC" "VALID" "$(python3 "$TH" jsonc-valid "$cfg")"
  chk_eq "opencode itself accepts the result" 0 \
    "$(timeout 90 opencode mcp list >/dev/null 2>&1; echo $?)"
  chk_not_contains "opencode no longer lists cosift" \
    "$(timeout 90 opencode mcp list 2>&1)" "cosift"
  chk_contains "line comments survive" "$(cat "$cfg")" "KEEPME-TOP"
  chk_contains "block comments survive" "$(cat "$cfg")" "KEEPME-BLOCK"
  chk_contains "other top-level keys survive" \
    "$(python3 "$TH" jsonc-topkeys "$cfg")" "autoshare"
  chk_contains "\$schema survives" "$(python3 "$TH" jsonc-topkeys "$cfg")" "\$schema"
  if [ "$2" = yes ]; then
    chk_contains "sibling server survives" "$(python3 "$TH" jsonc-names "$cfg")" "weather"
    chk_contains "brace/quote-bearing string value survives" "$(cat "$cfg")" \
      "KEEPME-STRING"
  fi
  chk_not_contains "stale token is gone from the file" "$(cat "$cfg")" "$STALE_TOKEN"
  chk_contains "a backup of the pre-edit file exists" "$(backup_list)" \
    "opencode.json.cosift-backup-"
  local bk
  bk=$(backup_list | grep 'opencode\.json\.cosift-backup-' | head -1)
  if [ -n "$bk" ]; then
    chk_eq "backup holds the original bytes" "$before" "$(cat "$bk")"
  fi
  mock_stop
}

case_C17() { opencode_torture torture-cosift-last.opencode.json yes; }
case_C18() { opencode_torture torture-cosift-first.opencode.json yes; }
case_C19() { opencode_torture torture-cosift-only.opencode.json no; }

case_C20() {
  mock_start ok || return 1
  local cfg="$HOME/.config/opencode/opencode.json"
  fixture opencode/restore-required.opencode.json "$cfg"
  set_paths
  local before
  before=$(sha_of "$cfg")
  cd "$HOME" || return 1
  install_notty --uninstall --harness=opencode
  chk "exit code is non-zero" "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
  chk_eq "config restored to the original bytes" "$before" "$(sha_of "$cfg")"
  chk_contains "cosift entry still present after restore" \
    "$(python3 "$TH" jsonc-names "$cfg")" "cosift"
  chk_contains "prints manual removal guidance" \
    "$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')" "manual"
  chk_contains "names the file the user must edit" "$OUT" "opencode.json"
  mock_stop
}

case_C21() {
  export COSIFT_EXTRA_HEADER="$EXTRA_HEADER_NAME: $EXTRA_HEADER_VALUE"
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "exit code" 0 "$RC"

  local hdr lc
  local hn
  hn=$(printf '%s' "$EXTRA_HEADER_NAME" | tr 'A-Z' 'a-z')
  local p
  for p in /auth/start /auth/verify /v1/mcp; do
    hdr=$(python3 "$TH" req-header "$MOCK_LOG" POST "$p" "$hn")
    lc=$(printf '%s\n' "$hdr" | grep -c "^${EXTRA_HEADER_VALUE}$" || true)
    chk_eq "extra header sent on every POST $p" "$(nreq POST "$p")" "$lc"
  done

  local e
  e=$(python3 "$TH" claude-entry "$CLAUDE_CFG" cosift)
  chk_contains "claude config carries the extra header" "$e" "$EXTRA_HEADER_VALUE"
  chk_contains "codex config carries the extra header" \
    "$(python3 "$TH" toml-entry "$CODEX_CFG" cosift)" "$EXTRA_HEADER_VALUE"
  opencode_cfg >/dev/null
  chk_contains "opencode config carries the extra header" \
    "$(python3 "$TH" jsonc-entry "$OPENCODE_CFG" cosift)" "$EXTRA_HEADER_VALUE"
  chk_contains "opencode extra header name kept intact (KEY=VALUE split)" \
    "$(python3 "$TH" jsonc-entry "$OPENCODE_CFG" cosift)" "$EXTRA_HEADER_NAME"
  unset COSIFT_EXTRA_HEADER
  mock_stop
}

case_C22() {
  export XDG_CONFIG_HOME="$HOME/xdg"
  mkdir -p "$XDG_CONFIG_HOME"
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="y
$EMAIL
123456"
  install_pty --harness=claude,codex
  chk_eq "exit code" 0 "$RC"
  assert_installed claude codex
  chk_eq "opencode was NOT configured" "NOFILE" \
    "$(python3 "$TH" jsonc-entry "$XDG_CONFIG_HOME/opencode/opencode.json" cosift)"
  chk_eq "opencode.jsonc was NOT created either" "NOFILE" \
    "$(python3 "$TH" jsonc-entry "$XDG_CONFIG_HOME/opencode/opencode.jsonc" cosift)"
  chk_eq "state.json honours XDG_CONFIG_HOME" "yes" \
    "$([ -f "$XDG_CONFIG_HOME/cosift/state.json" ] && echo yes || echo no)"
  chk_eq "state lists exactly the two selected harnesses" "ok" \
    "$(python3 "$TH" state-check "$XDG_CONFIG_HOME/cosift/state.json" \
       "claude,codex" "$(installer_version)" "claude,codex")"
  unset XDG_CONFIG_HOME
  mock_stop
}

case_C23() {
  mock_start ok || return 1
  cd "$HOME" || return 1
  install_split --help
  chk_eq "--help exit code" 0 "$RC"
  chk "--help writes to stdout" "$([ -n "$STDOUT" ] && echo 0 || echo 1)"
  chk_contains "--help documents COSIFT_AUTH_BASE" "$STDOUT" "COSIFT_AUTH_BASE"
  chk_contains "--help documents COSIFT_MCP_URL" "$STDOUT" "COSIFT_MCP_URL"
  chk_contains "--help documents COSIFT_EXTRA_HEADER" "$STDOUT" "COSIFT_EXTRA_HEADER"
  chk_contains "--help documents --dry-run" "$STDOUT" "--dry-run"
  chk_contains "--help documents --uninstall" "$STDOUT" "--uninstall"
  chk_contains "--help documents --harness" "$STDOUT" "--harness"
  chk_not_contains "--help never mentions unsupported harnesses" \
    "$(printf '%s' "$STDOUT" | tr 'A-Z' 'a-z')" "hermes"

  install_split --version
  chk_eq "--version exit code" 0 "$RC"
  chk "--version writes to stdout" "$([ -n "$STDOUT" ] && echo 0 || echo 1)"

  install_split --definitely-not-an-option
  chk_eq "unknown option exit code" 2 "$RC"
  chk "unknown option writes usage to stderr" "$([ -n "$STDERR" ] && echo 0 || echo 1)"

  chk_eq "no network traffic for --help/--version" 0 "$(nreq '*' /auth/start)"
  mock_stop
}

case_C24() { # root: strip all three harness CLIs, clean HOME
  local h
  for h in claude codex opencode; do rm -f "$(command -v "$h" 2>/dev/null)"; done
  mock_start ok || return 1
  install -d -m 0755 -o tester -g tester /home/tester/empty
  OUT=$(su tester -c "HOME=/home/tester/empty COSIFT_AUTH_BASE=$AUTH_BASE \
        COSIFT_MCP_URL=$MCP_URL timeout 90 sh $INSTALL_SH --yes </dev/null 2>&1")
  RC=$?
  chk_eq "exit code is 3 (nothing to configure)" 3 "$RC"
  chk_eq "no auth traffic" 0 "$(nreq POST /auth/start)"
  chk_not_contains "does not name unsupported harnesses" \
    "$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')" "hermes"
  mock_stop
}

case_C25() { # root: remove curl entirely
  mock_start ok || return 1
  local c
  for c in $(type -a -p curl 2>/dev/null); do rm -f "$c"; done
  hash -r
  if command -v curl >/dev/null 2>&1; then
    echo "    (could not remove curl from the image)"
    return 1
  fi
  install -d -m 0755 -o tester -g tester /home/tester/nocurl
  OUT=$(su tester -c "HOME=/home/tester/nocurl COSIFT_AUTH_BASE=$AUTH_BASE \
        COSIFT_MCP_URL=$MCP_URL timeout 90 sh $INSTALL_SH --yes </dev/null 2>&1")
  RC=$?
  chk_eq "exit code is 3 (preflight)" 3 "$RC"
  chk_contains "names curl as the missing dependency" \
    "$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')" "curl"
  mock_stop
}

case_C26() { # root: HOME exists but is not writable by the running user
  mock_start ok || return 1
  install -d -m 0555 -o root -g root /home/tester/rohome
  OUT=$(su tester -c "HOME=/home/tester/rohome COSIFT_AUTH_BASE=$AUTH_BASE \
        COSIFT_MCP_URL=$MCP_URL timeout 90 sh $INSTALL_SH --yes </dev/null 2>&1")
  RC=$?
  chk_eq "exit code is 3 (preflight)" 3 "$RC"
  chk_eq "nothing was written into the read-only HOME" "" \
    "$(find /home/tester/rohome -mindepth 1 2>/dev/null)"
  mock_stop
}

case_C27() { # no endpoint overrides at all: the shipped defaults must be sane
  mock_start ok || return 1
  cd "$HOME" || return 1
  OUT=$(env -u COSIFT_AUTH_BASE -u COSIFT_MCP_URL \
        timeout 90 sh "$INSTALL_SH" --dry-run --yes </dev/null 2>&1)
  RC=$?
  chk_eq "default dry-run exit code" 0 "$RC"
  chk_contains "default MCP URL is the production origin" "$OUT" \
    "cosift-mcp-udik5erlkq-uw.a.run.app/v1/mcp"
  install_split --help
  chk_contains "--help documents the production auth origin" "$OUT" \
    "cosift-auth-udik5erlkq-uw.a.run.app"
  chk_contains "--help documents the production MCP origin" "$OUT" \
    "cosift-mcp-udik5erlkq-uw.a.run.app/v1/mcp"
  chk_eq "the mock saw no traffic (nothing was pointed at it)" 0 \
    "$(nreq '*' /auth/start)"
  mock_stop
}

case_C28() {
  mock_start ok || return 1
  fixture claude/stale-token.claude.json "$HOME/.claude.json"
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "exit code" 0 "$RC"
  chk "the stale token was offered to the MCP endpoint" \
    "$(python3 "$TH" req-header "$MOCK_LOG" POST /v1/mcp authorization \
       | grep -qF "$STALE_TOKEN" && echo 0 || echo 1)"
  chk_eq "fell through to the email flow" 1 "$(nreq POST /auth/start)"
  local e
  e=$(python3 "$TH" claude-entry "$CLAUDE_CFG" cosift)
  chk_contains "claude entry now holds the fresh token" "$e" "Bearer $MINTED_TOKEN"
  chk_not_contains "stale token replaced, not kept" "$e" "$STALE_TOKEN"
  mock_stop
}

case_C29() {
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "exit code" 0 "$RC"
  chk_not_contains "token never printed in full" "$OUT" "$MINTED_TOKEN"

  set_paths
  opencode_cfg >/dev/null
  local hits allowed bad f
  hits=$(grep -rlF "$MINTED_TOKEN" "$HOME" 2>/dev/null | sort)
  allowed="$CLAUDE_CFG
$CODEX_CFG
$OPENCODE_CFG"
  bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # harness-owned caches/logs are the harness's business, not the installer's
    case "$f" in
      *.cosift-backup-*) continue ;;
      # The onboarding paths are ours, so they stay in scope even though they sit
      # under directories the harnesses otherwise own.
      "$HOME"/.claude/skills/*|"$HOME"/.local/bin/*) ;;
      "$HOME"/.claude/*|"$HOME"/.codex/*|"$HOME"/.cache/*) continue ;;
      "$HOME"/.local/share/opencode/*|"$HOME"/.local/state/*) continue ;;
    esac
    if ! printf '%s\n' "$allowed" | grep -qxF "$f"; then bad="$bad$f
"; fi
  done <<<"$hits"
  chk_eq "token lives only in the three harness configs" "" "$bad"
  chk_not_contains "token is not in state.json" "$(cat "$(state_path)")" "$MINTED_TOKEN"
  mock_stop
}

case_C30() {
  local orig
  fixture claude/unparseable-two-docs.claude.json /tmp/cosift-test/c30-original.json
  orig=$(sha_of /tmp/cosift-test/c30-original.json)
  refuse_case claude/unparseable-two-docs.claude.json "$HOME/.claude.json" claude
  chk_not_contains "does not report success" "$OUT" "Done."
  chk_contains "pre-existing 'weather' server survives" \
    "$(cat "$HOME/.claude.json" 2>/dev/null)" '"weather"'
  chk_contains "distinctive top-level key survives" \
    "$(cat "$HOME/.claude.json" 2>/dev/null)" "KEEPME-CLAUDE-TOPKEY"
  local b bad=""
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ "$(sha_of "$b")" = "$orig" ] || bad="$bad$b "
  done <<<"$(backup_list | grep '\.claude\.json\.cosift-backup-')"
  chk_eq "every claude backup holds the original bytes" "" "$bad"
}

case_C31() {
  mock_start ok || return 1
  fixture codex/unclosed-marker.config.toml "$HOME/.codex/config.toml"
  set_paths
  local before
  before=$(sha_of "$CODEX_CFG")
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="y
$EMAIL
123456"
  install_pty --harness=codex
  chk_eq "exit code is 5 (refusal)" 5 "$RC"
  chk_contains "[profiles.work] survives" \
    "$(cat "$CODEX_CFG" 2>/dev/null)" "[profiles.work]"
  chk_contains "the keys under [profiles.work] survive" \
    "$(cat "$CODEX_CFG" 2>/dev/null)" "KEEPME-PROFILE"
  chk_eq "the config we refused is byte-identical" "$before" "$(sha_of "$CODEX_CFG")"
  chk_eq "no second marker block was appended" 1 \
    "$(grep -c '>>> cosift' "$CODEX_CFG" 2>/dev/null || echo 0)"
  chk_contains "names the file the user has to inspect" "$OUT" "config.toml"
  chk_not_contains "token not printed in full" "$OUT" "$MINTED_TOKEN"
  mock_stop
}

# Codex is detected from the config file alone, so the refusal has to hold with
# the codex binary off PATH -- that is the branch nothing else validates.
foreign_table_case() { # foreign_table_case <fixture> <label>
  mock_start ok || return 1
  rm -rf "$HOME/.codex"
  fixture "codex/$1" "$HOME/.codex/config.toml"
  set_paths
  local before oldpath
  before=$(sha_of "$CODEX_CFG")
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="y
$EMAIL
123456"
  oldpath="$PATH"
  export PATH=/usr/bin:/bin
  install_pty --harness=codex
  export PATH="$oldpath"
  chk_eq "$2: exit code is 5 (refusal)" 5 "$RC"
  chk_eq "$2: the config we refused is byte-identical" "$before" "$(sha_of "$CODEX_CFG")"
  chk_not_contains "$2: no marker block was appended" \
    "$(cat "$CODEX_CFG" 2>/dev/null)" ">>> cosift"
  chk_eq "$2: the file still names cosift exactly once" 1 \
    "$(grep -c cosift "$CODEX_CFG" 2>/dev/null || echo 0)"
  chk_not_contains "$2: config.toml still parses as TOML" \
    "$(python3 "$TH" toml-entry "$CODEX_CFG" cosift)" "PARSE_ERROR"
  chk_eq "$2: codex itself still reads its config" 0 \
    "$(timeout 60 codex mcp list >/dev/null 2>&1; echo $?)"
  mock_stop
}

case_C32() {
  foreign_table_case foreign-cosift-quoted.config.toml 'quoted spelling'
  foreign_table_case foreign-cosift-padded.config.toml 'padded spelling'
}

reject_extra_header() { # reject_extra_header <label> <COSIFT_EXTRA_HEADER value>
  local before
  before=$(manifest_of)
  : >"$MOCK_LOG"
  export COSIFT_EXTRA_HEADER="$2"
  install_notty --yes
  chk_eq "$1: exit code is 2 (rejected as a usage error)" 2 "$RC"
  chk_eq "$1: no request reached either endpoint" "" \
    "$(python3 "$TH" all-paths "$MOCK_LOG")"
  chk_eq "$1: nothing under \$HOME was written" "" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$(manifest_of)") | head -20)"
  chk_contains "$1: the message names COSIFT_EXTRA_HEADER" "$OUT" "COSIFT_EXTRA_HEADER"
}

case_C33() {
  mock_start ok || return 1
  # a recoverable credential: without one the run stops at the tty prompt and
  # never reaches the curl call this case is about
  fixture claude/installed-token.claude.json "$HOME/.claude.json"
  set_paths
  cd "$HOME" || return 1
  rm -f /tmp/cosift-c33-PWNED
  reject_extra_header 'double quote' 'X-Gw: a"b'
  reject_extra_header 'backslash' 'X-Gw: back\slash'
  reject_extra_header 'embedded newline' \
    "$(printf 'X-Gw: ok\nurl = "%s/EXFIL"\noutput = "/tmp/cosift-c33-PWNED"' "$AUTH_BASE")"
  chk_eq "the injected curl directive never fired" 0 "$(nreq '*' /EXFIL)"
  chk_eq "no file was written by an injected curl directive" "no" \
    "$([ -e /tmp/cosift-c33-PWNED ] && echo yes || echo no)"
  unset COSIFT_EXTRA_HEADER
  mock_stop
}

case_C34() {
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/proj" && cd "$HOME/proj" || return 1
  timeout 60 claude mcp add --transport http cosift "$MCP_URL" \
    --header "Authorization: Bearer $MINTED_TOKEN" >/dev/null 2>&1
  local e
  e=$(python3 "$TH" claude-entry "$CLAUDE_CFG" cosift)
  chk_contains "seed: the entry is project-scoped" "$e" '"project_scopes": ["'
  chk_contains "seed: there is no user-scope entry yet" "$e" '"user_scope": null'

  cd "$HOME" || return 1
  install_notty --yes --harness=claude
  chk_eq "exit code" 0 "$RC"
  chk_not_contains "did not skip the write as already-up-to-date" \
    "$(printf '%s' "$OUT" | tr 'A-Z' 'a-z')" "up to date"
  chk_eq "a user-scope cosift entry now exists" 1 \
    "$(python3 "$TH" claude-names "$CLAUDE_CFG" | grep -c '^cosift$')"
  e=$(python3 "$TH" claude-entry "$CLAUDE_CFG" cosift)
  chk_contains "the user-scope entry carries the MCP url" "$e" "$MCP_URL"
  chk_contains "the user-scope entry carries the token" "$e" "Bearer $MINTED_TOKEN"
  chk_contains "claude lists cosift outside the project directory" \
    "$(timeout 60 claude mcp list 2>&1)" "cosift"
  mock_stop
}

case_C38() { # --uninstall reporting success while a project-scoped entry keeps a live token
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/proj" && cd "$HOME/proj" || return 1
  timeout 60 claude mcp add --transport http cosift "$MCP_URL" \
    --header "Authorization: Bearer $MINTED_TOKEN" >/dev/null 2>&1
  chk_contains "seed: the entry is project-scoped" \
    "$(python3 "$TH" claude-entry "$CLAUDE_CFG" cosift)" '"project_scopes": ["'

  cd "$HOME" || return 1
  install_notty --yes --harness=claude
  chk_eq "install exit code" 0 "$RC"

  install_notty --uninstall
  local left
  left=$(grep -c "$MINTED_TOKEN" "$CLAUDE_CFG" 2>/dev/null || true)
  [ -n "$left" ] || left=0
  chk_eq "no live credential remains anywhere in the claude config" 0 "$left"
  chk_contains "no user-scope entry remains" \
    "$(python3 "$TH" claude-entry "$CLAUDE_CFG" cosift)" '"user_scope": null'
  if [ "$left" -ne 0 ]; then
    chk "uninstall must not exit 0 while a credential remains" \
      "$([ "$RC" -ne 0 ] && echo 0 || echo 1)"
    chk_not_contains "uninstall must not claim removal while a credential remains" \
      "$OUT" "Removed."
  fi
  mock_stop
}

case_C35() { # root: uninstall with neither the claude binary nor curl present
  mock_start ok || return 1
  set_paths
  # a recoverable credential keeps the install non-interactive under `su`
  fixture claude/installed-token.claude.json "$HOME/.claude.json"
  chown tester:tester "$HOME/.claude.json"
  OUT=$(su tester -c "HOME=$HOME COSIFT_AUTH_BASE=$AUTH_BASE COSIFT_MCP_URL=$MCP_URL \
        timeout 120 sh $INSTALL_SH --yes </dev/null 2>&1")
  RC=$?
  chk_eq "install exit code" 0 "$RC"
  chk_eq "claude: our user-scope entry is present" 1 \
    "$(python3 "$TH" claude-names "$CLAUDE_CFG" | grep -c '^cosift$')"
  chk_contains "codex was configured" \
    "$(python3 "$TH" toml-entry "$CODEX_CFG" cosift)" "$MCP_URL"
  opencode_cfg >/dev/null
  chk_contains "opencode was configured" \
    "$(python3 "$TH" jsonc-entry "$OPENCODE_CFG" cosift)" "$MCP_URL"

  local b
  for b in $(type -a -p claude 2>/dev/null) $(type -a -p curl 2>/dev/null); do
    rm -f "$b"
  done
  hash -r
  chk_eq "claude is no longer on PATH" "" "$(command -v claude 2>/dev/null)"
  chk_eq "curl is no longer on PATH" "" "$(command -v curl 2>/dev/null)"

  : >"$MOCK_LOG"
  OUT=$(su tester -c "HOME=$HOME COSIFT_AUTH_BASE=$AUTH_BASE COSIFT_MCP_URL=$MCP_URL \
        timeout 90 sh $INSTALL_SH --uninstall </dev/null 2>&1")
  RC=$?
  chk "uninstall did not hang" "$([ "$RC" -ne 124 ] && echo 0 || echo 1)"
  chk "uninstall did not die in preflight over the missing curl" \
    "$([ "$RC" -ne 3 ] && echo 0 || echo 1)"
  chk_eq "uninstall made no network calls" "" "$(python3 "$TH" all-paths "$MOCK_LOG")"
  assert_absent codex opencode
  chk_eq "claude: the entry it could not remove is left in place" 1 \
    "$(python3 "$TH" claude-names "$CLAUDE_CFG" | grep -c '^cosift$')"
  chk_matches "tells the user how to remove the claude entry by hand" "$OUT" \
    "claude mcp remove cosift|\.claude\.json"
  mock_stop
}

case_C36() {
  mock_start ok || return 1
  fixture codex/stale-token.config.toml "$HOME/.codex/config.toml"
  set_paths
  chmod 0644 "$CODEX_CFG"
  chk_file_mode "the pre-existing config starts out world-readable" "$CODEX_CFG" 644
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="y
$EMAIL
123456"
  install_pty --harness=codex
  chk_eq "exit code" 0 "$RC"
  chk_contains "the codex config holds the fresh bearer token" \
    "$(cat "$CODEX_CFG" 2>/dev/null)" "Bearer $MINTED_TOKEN"
  chk_file_mode "codex config is 0600 once it holds a token" "$CODEX_CFG" 600
  local b bad=""
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    grep -q 'ck_' "$b" 2>/dev/null || continue
    [ "$(stat -c '%a' "$b" 2>/dev/null)" = "600" ] || bad="$bad$b "
  done <<<"$(backup_list)"
  chk_eq "every token-bearing backup is 0600" "" "$bad"
  # Changing the mode of a user's file is disclosed, whatever words are used for it.
  chk_matches "the summary discloses the mode change" "$OUT" \
    "0600|tighten|readable by other|world-readable|group-readable|too permissive"
  chk_contains "and names the file it changed" "$OUT" "$CODEX_CFG"
  mock_stop
}

case_C37() {
  mock_start ok || return 1
  fixture codex/other-server.config.toml "$HOME/.codex/config.toml"
  set_paths
  local orig oldpath
  orig=$(sha_of "$CODEX_CFG")
  # freeze the backup stamp so the same-second collision is deterministic
  mkdir -p "$HOME/bin"
  cat >"$HOME/bin/date" <<'DATEEOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in
    "+%Y%m%dT%H%M%SZ") echo "20260101T000000Z"; exit 0 ;;
  esac
done
exec /usr/bin/date "$@"
DATEEOF
  chmod 0755 "$HOME/bin/date"
  oldpath="$PATH"
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1

  PTY_LINES="y
$EMAIL
123456"
  export PATH="$HOME/bin:$oldpath"
  install_pty --harness=codex
  export PATH="$oldpath"
  chk_eq "install exit code" 0 "$RC"

  PTY_LINES=""
  export PATH="$HOME/bin:$oldpath"
  install_notty --uninstall --harness=codex
  export PATH="$oldpath"
  chk_eq "uninstall exit code" 0 "$RC"

  chk "the frozen clock did force a same-second backup name" \
    "$([ "$(backup_list | grep -c 'cosift-backup-20260101T000000Z')" -ge 1 ] \
      && echo 0 || echo 1)"
  chk_eq "both edits of config.toml kept their own backup" 2 \
    "$(backup_list | grep -c 'config\.toml\.cosift-backup-')"
  local b found_orig=no found_token=no
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ "$(sha_of "$b")" = "$orig" ] && found_orig=yes
    grep -q "$MINTED_TOKEN" "$b" 2>/dev/null && found_token=yes
  done <<<"$(backup_list | grep 'config\.toml\.cosift-backup-')"
  chk_eq "the pre-install backup still holds the original config" "yes" "$found_orig"
  chk_eq "the pre-uninstall backup still holds the installed config" "yes" "$found_token"
  mock_stop
}

case_C39() {
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes            # --yes implies --onboarding
  chk_eq "exit code" 0 "$RC"
  assert_installed claude codex opencode
  assert_onboarding_installed claude codex opencode
  assert_cmd_installed

  chk_exists "codex artifact was not written under \$CODEX_HOME" \
    "${CODEX_HOME:-$HOME/.codex}/skills/cosift-onboarding" no
  chk_eq "state.json shape/mode with the onboarding keys" "ok" \
    "$(python3 "$TH" state-check "$(state_path)" "claude,codex,opencode" \
       "$(installer_version)" "claude,codex,opencode")"
  chk_eq "state records the command path" "$(onb_cmd)" \
    "$(python3 "$TH" json-get "$(state_path)" onboarding_cmd)"
  chk_contains "summary shows the slash invocation" "$OUT" "/cosift-onboarding"
  chk_contains "summary shows the codex invocation" "$OUT" "\$cosift-onboarding"
  chk_eq "no artifact was backed up on a clean box" "" \
    "$(onb_backups claude)$(onb_backups codex)$(onb_backups opencode)"

  # the codex skills root is overridable and is not under $CODEX_HOME
  export COSIFT_CODEX_SKILLS_DIR="$HOME/alt-agents/skills"
  PTY_LINES=""
  install_notty --yes
  chk_eq "override run exit code" 0 "$RC"
  assert_onboarding_installed codex
  unset COSIFT_CODEX_SKILLS_DIR
  mock_stop
}

case_C40() {
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "first run exit code" 0 "$RC"
  assert_onboarding_installed claude codex opencode
  local b1 m1
  b1=$(backup_list | wc -l)
  # state.json holds installed_at, which a second install legitimately refreshes
  m1=$(manifest_of | grep -v 'cosift/state.json')

  PTY_LINES=""
  install_notty --yes
  chk_eq "second run exit code" 0 "$RC"
  assert_onboarding_installed claude codex opencode
  assert_cmd_installed
  chk_eq "no artifact grew a backup on the second run" "" \
    "$(onb_backups claude)$(onb_backups codex)$(onb_backups opencode)"
  chk_eq "backup count unchanged by the no-op run" "$b1" "$(backup_list | wc -l)"
  chk_eq "\$HOME is byte-identical, state.json aside, after the second run" "" \
    "$(diff <(printf '%s\n' "$m1") \
        <(printf '%s\n' "$(manifest_of | grep -v 'cosift/state.json')") | head -40)"
  chk_matches "the second run reports the artifacts are already up to date" "$OUT" \
    "up to date"
  mock_stop
}

case_C41() {
  mock_start ok || return 1
  set_paths
  seed_all_fixtures
  # the shared dirs exist beforehand so a stray write lands inside the manifest
  mkdir -p "$HOME/.claude/skills" "$HOME/.agents/skills" \
           "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/commands" "$HOME/.local/bin"
  cd "$HOME" || return 1
  local before after
  before=$(manifest_of)
  install_notty --dry-run --yes
  chk_eq "exit code" 0 "$RC"
  after=$(manifest_of)
  chk_eq "\$HOME is byte-identical after --dry-run" "" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -40)"
  assert_onboarding_absent claude codex opencode
  chk_exists "no state command" "$(onb_cmd)" no
  chk_exists "no settings.json" "$(claude_settings)" no
  chk_exists "no owned dir for claude" "$(onb_owned_dir claude)" no
  chk_exists "no owned dir for codex" "$(onb_owned_dir codex)" no
  chk_eq "no backups created" 0 "$(backup_list | wc -l)"
  chk_matches "the plan mentions the onboarding interview" "$OUT" "onboarding"
  mock_stop
}

case_C42() {
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/.local/bin" && : >"$HOME/.local/bin/keepme"
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "install exit code" 0 "$RC"
  assert_onboarding_installed claude codex opencode
  assert_cmd_installed
  # what the state command leaves behind when state.json is absent
  printf '{"onboarded":true,"onboarding_version":"1.0.0"}\n' >"$(onb_json)"

  PTY_LINES=""
  install_notty --uninstall
  chk_eq "uninstall exit code" 0 "$RC"
  assert_onboarding_absent claude codex opencode
  chk_exists "claude: the owned dir is gone" "$(onb_owned_dir claude)" no
  chk_exists "codex: the owned dir is gone" "$(onb_owned_dir codex)" no
  chk_exists "the state command is gone" "$(onb_cmd)" no
  chk_eq "no cosift entry is left in settings.json" "" \
    "$(grep -l cosift "$(claude_settings)" 2>/dev/null)"
  chk_exists "onboarding.json is gone" "$(onb_json)" no
  chk_exists "state.json is gone" "$(state_path)" no
  local h
  for h in claude codex opencode; do
    chk_exists "$h: the shared parent survives an empty uninstall" \
      "$(onb_shared_parent "$h")" yes
  done
  chk_exists "an unrelated file in ~/.local/bin survives" "$HOME/.local/bin/keepme" yes
  mock_stop
}

# The artifact must never be written into a file a harness always loads.
DENY_FILES="CLAUDE.md
.claude/CLAUDE.md
AGENTS.md
AGENTS.override.md
SOUL.md
.codex/AGENTS.md
.codex/AGENTS.override.md
.agents/AGENTS.md
.agents/skills/AGENTS.md
.config/opencode/AGENTS.md
.config/opencode/commands/AGENTS.md
.config/opencode/SOUL.md
work/CLAUDE.md
work/AGENTS.md
work/AGENTS.override.md
work/SOUL.md"

deny_shas() {
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    printf '%s %s\n' "$rel" "$(sha_of "$HOME/$rel")"
  done <<<"$DENY_FILES"
}

case_C43() {
  mock_start ok || return 1
  set_paths
  local rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in */*) mkdir -p "$HOME/${rel%/*}" ;; esac
    printf 'KEEPME-DENYLIST %s\nalways loaded; never ours to edit.\n' "$rel" \
      >"$HOME/$rel"
  done <<<"$DENY_FILES"
  local before
  before=$(deny_shas)

  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "install exit code" 0 "$RC"
  assert_onboarding_installed claude codex opencode
  chk_eq "every always-loaded file is byte-identical after install" "" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$(deny_shas)") | head -40)"
  local tainted=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    grep -qF "cosift-onboarding" "$HOME/$rel" 2>/dev/null && tainted="$tainted$rel "
  done <<<"$DENY_FILES"
  chk_eq "no always-loaded file mentions the interview" "" "$tainted"

  PTY_LINES=""
  install_notty --uninstall
  chk_eq "uninstall exit code" 0 "$RC"
  chk_eq "every always-loaded file is byte-identical after uninstall" "" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$(deny_shas)") | head -40)"
  mock_stop
}

case_C44() {
  mock_start ok || return 1
  set_paths
  local h p
  for h in claude codex opencode; do
    p=$(onb_artifact "$h")
    mkdir -p "${p%/*}"
    fixture onboarding/foreign.skill.md "$p"
    printf 'harness marker: %s\n' "$h" >>"$p"
  done
  local claude_before codex_before oc_before
  claude_before=$(sha_of "$(onb_artifact claude)")
  codex_before=$(sha_of "$(onb_artifact codex)")
  oc_before=$(sha_of "$(onb_artifact opencode)")

  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "exit code" 0 "$RC"
  assert_onboarding_installed claude codex opencode
  backups_wellformed
  chk "every backup name matches <path>.cosift-backup-<UTC>" $?

  chk_eq "claude: exactly one backup of the foreign file" 1 "$(onb_backups claude | wc -l)"
  chk_eq "codex: exactly one backup of the foreign file" 1 "$(onb_backups codex | wc -l)"
  chk_eq "opencode: exactly one backup of the foreign file" 1 \
    "$(onb_backups opencode | wc -l)"
  chk_eq "claude: the backup holds the foreign bytes" "$claude_before" \
    "$(sha_of "$(onb_backups claude | head -1)")"
  chk_eq "codex: the backup holds the foreign bytes" "$codex_before" \
    "$(sha_of "$(onb_backups codex | head -1)")"
  chk_eq "opencode: the backup holds the foreign bytes" "$oc_before" \
    "$(sha_of "$(onb_backups opencode | head -1)")"
  chk_matches "stdout says a file was backed up" "$OUT" "backed up|backup"
  chk_contains "stdout names the file it replaced" "$OUT" "cosift-onboarding"
  mock_stop
}

case_C45() {
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --no-onboarding --harness=claude,codex,opencode
  chk_eq "--no-onboarding exit code" 0 "$RC"
  assert_installed claude codex opencode
  assert_onboarding_absent claude codex opencode
  chk_exists "--no-onboarding wrote no state command" "$(onb_cmd)" no
  chk_eq "--no-onboarding wrote no session-start hook" "" \
    "$(grep -l 'cosift-onboarding' "$(claude_settings)" 2>/dev/null)"
  chk_eq "state records no onboarding harnesses" "[]" \
    "$(python3 "$TH" json-get "$(state_path)" onboarding_installed)"

  # no flag and no usable tty: skip, and never write without consent
  PTY_LINES=""
  install_notty --harness=claude
  chk "no-tty run ended 0 (skipped) or 6 (needs a tty), not in a write" \
    "$([ "$RC" -eq 0 ] || [ "$RC" -eq 6 ] && echo 0 || echo 1)"
  assert_onboarding_absent claude codex opencode
  chk_exists "no-tty run wrote no state command" "$(onb_cmd)" no
  if [ "$RC" -eq 0 ]; then
    chk_contains "tells the user how to add it later" "$OUT" "--onboarding"
  fi

  local before
  before=$(manifest_of)
  install_notty --onboarding --no-onboarding
  chk_eq "both onboarding flags together is a usage error" 2 "$RC"
  chk_eq "the usage error wrote nothing" "" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$(manifest_of)") | head -20)"
  mock_stop
}

case_C46() {
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "install exit code" 0 "$RC"
  assert_onboarding_installed claude codex opencode

  local desc
  desc=$(sed -n 's/^description: //p' "$(onb_source opencode)" | head -1 | cut -c1-60)

  if onb_is_stub opencode; then
    chk_skip "opencode discovery: the image fell back to the stub CLI" \
      "DISCOVERY: UNPROVEN (opencode)"
  else
    local port=4599 log=/tmp/cosift-test/opencode-serve.log body="" sp i
    opencode serve --pure --hostname 127.0.0.1 --port "$port" >"$log" 2>&1 &
    sp=$!
    for i in $(seq 1 60); do
      body=$(curl -fsS "http://127.0.0.1:$port/command" 2>/dev/null) || body=""
      [ -n "$body" ] && break
      sleep 0.5
    done
    kill "$sp" 2>/dev/null
    wait "$sp" 2>/dev/null
    if [ -z "$body" ]; then
      chk_skip "opencode discovery: 'opencode serve --pure' served no /command listing" \
        "DISCOVERY: UNPROVEN (opencode)" \
        "serve log: $(tail -3 "$log" 2>/dev/null | tr '\n' ' ')"
    else
      chk_contains "opencode lists /cosift-onboarding" "$body" "cosift-onboarding"
      chk_contains "opencode read our file (description matches)" "$body" "$desc"
    fi
  fi

  if onb_is_stub codex; then
    chk_skip "codex discovery: the image fell back to the stub CLI" \
      "DISCOVERY: UNPROVEN (codex)"
  else
    local cout crc
    cout=$(timeout 90 codex debug prompt-input 2>&1)
    crc=$?
    if [ "$crc" -ne 0 ]; then
      chk_skip "codex discovery: 'codex debug prompt-input' is unavailable (exit $crc)" \
        "DISCOVERY: UNPROVEN (codex)" \
        "codex said: $(printf '%s' "$cout" | head -3 | tr '\n' ' ')"
    else
      chk_contains "codex renders the skill from the ~/.agents/skills root" \
        "$cout" "cosift-onboarding"
    fi
  fi

  # Claude Code 2.x exposes no no-auth listing of installed skills
  chk_skip "claude discovery: no no-auth listing exists to ask" \
    "DISCOVERY: UNPROVEN (claude)"
  mock_stop
}

case_C47() {
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "install exit code" 0 "$RC"
  assert_cmd_installed

  local cmd state out rc
  cmd=$(onb_cmd)
  state=$(state_path)
  cp "$state" /tmp/cosift-test/c47-fresh.json

  out=$("$cmd" status 2>/dev/null); rc=$?
  chk_eq "status word on a fresh install" "pending" "$out"
  chk_eq "status exit code on a fresh install" 0 "$rc"

  out=$("$cmd" complete 2>&1); rc=$?
  chk_eq "complete exit code" 0 "$rc"
  chk_eq "complete set onboarded true" "true" \
    "$(python3 "$TH" json-get "$state" onboarded)"
  chk_matches "complete stamped onboarded_at" \
    "$(python3 "$TH" json-get "$state" onboarded_at)" \
    "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
  chk_not_contains "complete recorded the version it ran" \
    "$(python3 "$TH" json-get "$state" onboarding_version)" "MISSING"
  chk_eq "complete preserved account_uid" \
    "$(python3 "$TH" json-get /tmp/cosift-test/c47-fresh.json account_uid)" \
    "$(python3 "$TH" json-get "$state" account_uid)"
  chk_eq "complete preserved harnesses_configured" \
    "$(python3 "$TH" json-get /tmp/cosift-test/c47-fresh.json harnesses_configured)" \
    "$(python3 "$TH" json-get "$state" harnesses_configured)"
  chk_eq "complete preserved onboarding_installed" \
    "$(python3 "$TH" json-get /tmp/cosift-test/c47-fresh.json onboarding_installed)" \
    "$(python3 "$TH" json-get "$state" onboarding_installed)"

  out=$("$cmd" status 2>/dev/null); rc=$?
  chk_eq "status word once complete has run" "done" "$out"
  chk_eq "status exit code once complete has run" 1 "$rc"

  cp /tmp/cosift-test/c47-fresh.json "$state"
  out=$("$cmd" complete --declined 2>&1); rc=$?
  chk_eq "complete --declined exit code" 0 "$rc"
  out=$("$cmd" status 2>/dev/null); rc=$?
  chk_eq "status word after a decline" "declined" "$out"
  chk_eq "status exit code after a decline" 1 "$rc"

  printf '{ "version": 1, "onboarded": false,\n' >"$state"
  out=$("$cmd" status 2>/dev/null); rc=$?
  chk_eq "status word on a malformed state file" "malformed" "$out"
  chk_eq "status exit code on a malformed state file" 3 "$rc"

  rm -f "$state" "$(onb_json)"
  out=$("$cmd" status 2>/dev/null); rc=$?
  chk_eq "status word with no state file at all" "unknown" "$out"
  chk_eq "status exit code with no state file at all" 2 "$rc"
  mock_stop
}

case_C48() { # writing in place follows both symlinks and hard links to their target
  mock_start ok || return 1
  set_paths

  # claude: a symlink at the artifact path, aimed at the one class of file this artifact
  # must never be written into.
  mkdir -p "$HOME/.claude/skills/cosift-onboarding" "$HOME/.local/bin"
  printf 'KEEPME always-loaded instructions\n' >"$HOME/.claude/CLAUDE.md"
  ln -s "$HOME/.claude/CLAUDE.md" "$(onb_artifact claude)"
  # codex: a hard link, which no -L test can see. A home restored from an
  # rsync --link-dest snapshot is a hard-link farm, so this is not only an attack.
  mkdir -p "$(onb_owned_dir codex)"
  printf 'KEEPME hard-linked instructions\n' >"$HOME/.agents/AGENTS.md"
  ln "$HOME/.agents/AGENTS.md" "$(onb_artifact codex)"
  # the state command: also a hard link, into a directory full of other tools
  printf '#!/bin/sh\necho someone elses tool\n' >"$HOME/othertool"
  chmod 755 "$HOME/othertool"
  ln "$HOME/othertool" "$(onb_cmd)"

  local claude_md_before agents_md_before othertool_before
  claude_md_before=$(sha_of "$HOME/.claude/CLAUDE.md")
  agents_md_before=$(sha_of "$HOME/.agents/AGENTS.md")
  othertool_before=$(sha_of "$HOME/othertool")

  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "install exit code (a link refusal is not fatal)" 0 "$RC"

  chk_eq "the always-loaded file the symlink pointed at is untouched" \
    "$claude_md_before" "$(sha_of "$HOME/.claude/CLAUDE.md")"
  chk_eq "the always-loaded file the hard link pointed at is untouched" \
    "$agents_md_before" "$(sha_of "$HOME/.agents/AGENTS.md")"
  chk_eq "the binary the state-command hard link pointed at is untouched" \
    "$othertool_before" "$(sha_of "$HOME/othertool")"

  # A symlink is the user's own decision and is left alone; a hard link is invisible, so
  # the artifact is placed by rename and simply stops sharing the inode.
  chk_contains "the symlink refusal names it" "$OUT" "is a symlink"
  chk_same_bytes "codex received the interview despite the hard link" \
    "$(onb_artifact codex)" "$(onb_source codex)"
  chk_same_bytes "the state command was still installed" "$(onb_cmd)" "$(onb_cmd_source)"
  chk_same_bytes "opencode, with no link planted, was unaffected" \
    "$(onb_artifact opencode)" "$(onb_source opencode)"
  chk_eq "no temp file was left beside an artifact" "" \
    "$(find "$HOME" -name '.cosift-onboarding.*' 2>/dev/null)"

  install_notty --uninstall
  chk_eq "uninstall exit code" 0 "$RC"
  chk_exists "uninstall left the foreign symlink in place" "$(onb_artifact claude)" yes
  chk_eq "and its target is still untouched" \
    "$claude_md_before" "$(sha_of "$HOME/.claude/CLAUDE.md")"
  chk_eq "the hard-linked original is still untouched after uninstall" \
    "$othertool_before" "$(sha_of "$HOME/othertool")"
  mock_stop
}

case_C49() { # a later run must not strand interview files the state file has forgotten
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "first install exit code" 0 "$RC"
  assert_onboarding_installed claude codex opencode

  # The ordinary piped re-run: no tty, so consent is skipped and this run records that it
  # installed nothing. The three files from the first run are still on disk.
  install_notty --harness=claude
  chk_eq "re-run exit code" 0 "$RC"
  chk_contains "the re-run recorded an empty onboarding list" \
    "$(tr -d ' \n' <"$(state_path)")" '"onboarding_installed":[]'

  local h p left=""
  for h in claude codex opencode; do
    p=$(onb_artifact "$h")
    [ -f "$p" ] && left="$left$h "
  done
  chk_eq "the artifacts are still on disk after the re-run" "claude codex opencode " "$left"

  install_notty --uninstall
  chk_eq "uninstall exit code" 0 "$RC"
  left=""
  for h in claude codex opencode; do
    p=$(onb_artifact "$h")
    [ -e "$p" ] && left="$left$p "
  done
  chk_eq "uninstall removed every artifact, not just the ones state remembered" "" "$left"
  chk_exists "and the state command" "$(onb_cmd)" no
  chk_exists "the claude shared parent survives" "$HOME/.claude/skills" yes
  chk_exists "the codex shared parent survives" "$(onb_shared_parent codex)" yes
  mock_stop
}

case_C50() { # the user's own settings.json survives the hook and the permission grants
  mock_start ok || return 1
  set_paths
  local s seed seed_sha
  s=$(claude_settings)
  seed=/tmp/cosift-test/c50-seed.json
  fixture claude/seeded.settings.json "$s"
  cp "$s" "$seed"
  seed_sha=$(sha_of "$s")

  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes --harness=claude
  chk_eq "install exit code" 0 "$RC"
  assert_installed claude
  assert_onboarding_installed claude

  chk_eq "settings.json still parses" '"opusplan"' \
    "$(python3 "$TH" json-path "$s" model)"
  chk_eq "exactly one SessionStart hook is ours" 1 \
    "$(hook_cmds | grep -c 'cosift-onboarding' || true)"
  local ourcmd
  ourcmd=$(our_hook_cmd)
  chk_matches "our hook entry runs the hook subcommand" "$ourcmd" "cosift-onboarding.*hook"
  chk_matches "the command in settings.json really runs and asks for the interview" \
    "$(cd "$HOME" && sh -c "$ourcmd" 2>/dev/null)" "cosift-onboarding"

  local added t
  added=$(comm -13 <(python3 "$TH" allow-list "$seed" | sort) \
                   <(python3 "$TH" allow-list "$s" | sort))
  chk_eq "exactly five permissions were added" 5 "$(count_lines "$added")"
  for t in cosift_search cosift_lookup cosift_request cosift_topics cosift-onboarding; do
    chk_contains "the added permissions name $t" "$added" "$t"
  done

  local k
  for k in model cleanupPeriodDays env statusLine permissions.deny \
           permissions.defaultMode hooks.PostToolUse; do
    chk_eq "pre-existing $k is unchanged" "$(python3 "$TH" json-path "$seed" "$k")" \
      "$(python3 "$TH" json-path "$s" "$k")"
  done
  chk_eq "the user's own SessionStart hook survives verbatim" "SUPERSET" \
    "$(python3 "$TH" json-superset "$s" hooks.SessionStart "$seed" hooks.SessionStart)"
  chk_eq "the user's own permissions survive verbatim" "SUPERSET" \
    "$(python3 "$TH" json-superset "$s" permissions.allow "$seed" permissions.allow)"
  chk_contains "the status line command survives verbatim" "$(cat "$s")" "KEEPME-STATUSLINE"

  chk_eq "exactly one backup of settings.json" 1 "$(settings_backups | wc -l)"
  chk_eq "the backup holds the pre-install bytes" "$seed_sha" \
    "$(sha_of "$(settings_backups | head -1)")"
  backups_wellformed
  chk "every backup name matches <path>.cosift-backup-<UTC>" $?

  local after1 allow1
  after1=$(sha_of "$s")
  allow1=$(python3 "$TH" allow-list "$s" | wc -l)
  PTY_LINES=""
  install_notty --yes --harness=claude
  chk_eq "second install exit code" 0 "$RC"
  chk_eq "settings.json is byte-identical after the second install" "$after1" "$(sha_of "$s")"
  chk_eq "still exactly one SessionStart hook of ours" 1 \
    "$(hook_cmds | grep -c 'cosift-onboarding' || true)"
  chk_eq "no permission was duplicated" "$allow1" "$(python3 "$TH" allow-list "$s" | wc -l)"
  chk_eq "no second backup of settings.json" 1 "$(settings_backups | wc -l)"

  install_notty --uninstall
  chk_eq "uninstall exit code" 0 "$RC"
  chk_exists "the user's settings.json is still there" "$s" yes
  chk_eq "no hook of ours remains" 0 "$(hook_cmds | grep -c 'cosift' || true)"
  chk_eq "no permission of ours remains" 0 \
    "$(python3 "$TH" allow-list "$s" | grep -ci 'cosift' || true)"
  chk_eq "what is left is exactly the settings the user started with" "SAME" \
    "$(python3 "$TH" json-eq "$s" "$seed")"
  mock_stop
}

case_C51() { # a settings.json that does not parse is refused, never rewritten
  mock_start ok || return 1
  set_paths
  local s before
  s=$(claude_settings)
  fixture claude/unparseable.settings.json "$s"
  before=$(sha_of "$s")
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes --harness=claude
  chk_eq "the install still exits 0" 0 "$RC"
  chk_eq "the settings file we refused is byte-identical" "$before" "$(sha_of "$s")"
  chk_eq "it was not quarantined and reset" "PARSE_ERROR" \
    "$(python3 "$TH" json-path "$s" model)"
  chk_contains "the user's own keys are still in it" "$(cat "$s")" "KEEPME-BROKEN-SETTINGS"
  chk_contains "the warning names the file" "$OUT" "settings.json"
  chk_matches "the warning says it could not read it" "$OUT" \
    "could not|cannot|unreadable|does not parse|not valid|malformed|left it|skipp"
  assert_installed claude
  assert_onboarding_installed claude
  mock_stop
}

case_C52() { # the session-start directive, in every state the state file can be in
  mock_start ok || return 1
  set_paths
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes --harness=claude
  chk_eq "install exit code" 0 "$RC"
  assert_cmd_installed

  local cmd state err out rc
  cmd=$(onb_cmd)
  state=$(state_path)
  err=/tmp/cosift-test/c52-err.txt
  cp "$state" /tmp/cosift-test/c52-fresh.json

  out=$("$cmd" hook 2>"$err"); rc=$?
  chk_eq "pending: exit code" 0 "$rc"
  chk_contains "pending: names the interview to run" "$out" "cosift-onboarding"
  chk_matches "pending: run it only when the user asked for nothing" "$out" \
    "not asked|nothing specific|has not"
  chk_matches "pending: otherwise do their work first and mention it once at the end" \
    "$out" "first|at the end"
  chk_eq "pending: stderr is silent" "" "$(cat "$err")"

  "$cmd" complete >/dev/null 2>&1
  out=$("$cmd" hook 2>"$err"); rc=$?
  chk_eq "done: exit code" 0 "$rc"
  chk_eq "done: prints nothing at all" "" "$out"
  chk_eq "done: stderr is silent" "" "$(cat "$err")"

  cp /tmp/cosift-test/c52-fresh.json "$state"
  "$cmd" complete --declined >/dev/null 2>&1
  out=$("$cmd" hook 2>"$err"); rc=$?
  chk_eq "declined: exit code" 0 "$rc"
  chk_eq "declined: prints nothing at all" "" "$out"
  chk_eq "declined: stderr is silent" "" "$(cat "$err")"

  rm -f "$state" "$(onb_json)"
  out=$("$cmd" hook 2>"$err"); rc=$?
  chk_eq "no state file: exit code" 0 "$rc"
  chk_contains "no state file: still asks for the interview" "$out" "cosift-onboarding"
  chk_eq "no state file: stderr is silent" "" "$(cat "$err")"

  printf '{ "version": 1, "onboarded": false,\n' >"$state"
  out=$("$cmd" hook 2>"$err"); rc=$?
  chk_eq "corrupt state file: exit code is still 0" 0 "$rc"
  chk_eq "corrupt state file: stderr is silent" "" "$(cat "$err")"
  chk_not_contains "corrupt state file: no interpreter noise reaches the session" \
    "$out$(cat "$err")" "Traceback"
  mock_stop
}

case_C53() { # the digest offers subjects, never a path, an address or anything typed
  local h=/home/tester/dhome db before after
  rm -rf "$h"
  seed_digest_home "$h"
  db="$h/.local/share/opencode/opencode.db"
  seed_opencode_db "$db"
  local db_sha
  db_sha=$(sha_of "$db")
  before=$(python3 "$TH" manifest "$h")

  digest_run "$h"
  chk_eq "exit code" 0 "$DIGEST_RC"
  chk_eq "stderr is silent" "" "$DIGEST_ERR"
  chk_contains "a Claude Code title is offered" "$DIGEST_OUT" \
    "Payroll ledger reconciliation workflow"
  chk_contains "an opencode database title is offered" "$DIGEST_OUT" \
    "Sqlite index tuning for a catalogue"
  chk_eq "newest first" "Zephyr search relevance tuning" \
    "$(printf '%s\n' "$DIGEST_OUT" | head -1)"
  chk_eq "no blank lines between the titles" "" \
    "$(printf '%s\n' "$DIGEST_OUT" | grep -n '^$' || true)"

  chk_eq "no path or home reference anywhere in the output" "" \
    "$(printf '%s\n' "$DIGEST_OUT" | grep -n '[/\\~]' || true)"
  chk_eq "no URL anywhere in the output" "" \
    "$(printf '%s\n' "$DIGEST_OUT" | grep -Ein 'https?:|www\.' || true)"
  chk_eq "no e-mail address anywhere in the output" "" \
    "$(printf '%s\n' "$DIGEST_OUT" | grep -n '@' || true)"
  chk_not_contains "the path-bearing title was dropped whole, not cleaned" \
    "$DIGEST_OUT" "northwind-curation"
  chk_not_contains "the url-bearing title was dropped whole" "$DIGEST_OUT" \
    "intranet.northwind"
  chk_not_contains "the address-bearing title was dropped whole" "$DIGEST_OUT" "outage"
  chk_not_contains "the opencode path-bearing title was dropped whole" "$DIGEST_OUT" \
    "OPENCODEDROPCANARY"

  chk_not_contains "what the user typed never appears" "$DIGEST_OUT" "CANARYPROMPT"
  chk_not_contains "a tool call's own title is not a session title" "$DIGEST_OUT" \
    "TOOLTITLECANARY"
  chk_not_contains "a transcript summary is not a session title" "$DIGEST_OUT" \
    "SUMMARYCANARY"

  chk_not_contains "a 200-day-old session is outside the default window" "$DIGEST_OUT" \
    "Kernel module debugging"
  digest_run "$h" --days 3650
  chk_eq "--days 3650 exit code" 0 "$DIGEST_RC"
  chk_contains "--days widens the window" "$DIGEST_OUT" "Kernel module debugging"
  digest_run "$h" --max 3
  chk_eq "--max caps the list" 3 "$(count_lines "$DIGEST_OUT")"

  chk_eq "the opencode database is byte-identical after the run" "$db_sha" "$(sha_of "$db")"
  chk_eq "no journal or wal file was left beside it" "" \
    "$(find "${db%/*}" -maxdepth 1 -name 'opencode.db-*' 2>/dev/null)"
  after=$(python3 "$TH" manifest "$h")
  chk_eq "the digest wrote nothing at all" "" \
    "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -20)"

  rm -f "$db"
  digest_run "$h"
  chk_eq "legacy store: exit code" 0 "$DIGEST_RC"
  chk_contains "a legacy opencode session file is read when there is no database" \
    "$DIGEST_OUT" "Mastodon firehose ingestion backlog"

  local sparse=/home/tester/dhome-sparse empty=/home/tester/dhome-empty
  rm -rf "$sparse"
  mkdir -p "$sparse/.claude/projects/old"
  fixture digest/claude-old.jsonl "$sparse/.claude/projects/old/old.jsonl"
  touch -d "@$(( $(date +%s) - 200 * 86400 ))" "$sparse/.claude/projects/old/old.jsonl"
  digest_run "$sparse"
  chk_eq "sparse home: exit code" 0 "$DIGEST_RC"
  chk_contains "a sparse window widens instead of printing nothing" "$DIGEST_OUT" \
    "Kernel module debugging"

  rm -rf "$empty"
  mkdir -p "$empty"
  digest_run "$empty"
  chk_eq "no history: exit code is still 0" 0 "$DIGEST_RC"
  chk_eq "no history: prints nothing" "" "$DIGEST_OUT"
  chk_eq "no history: stderr is silent" "" "$DIGEST_ERR"
}

case_C54() { # colour decorates a terminal and never reaches a pipe
  mock_start ok || return 1
  set_paths
  seed_all_fixtures
  cd "$HOME" || return 1
  local colour nocolour dumb piped

  export TERM=xterm-256color
  PTY_LINES=""
  install_pty --dry-run --yes
  chk_eq "tty run exit code" 0 "$RC"
  colour="$OUT"
  chk "colour is used when stdout is a terminal" \
    "$(has_colour "$colour" && echo 0 || echo 1)"

  export NO_COLOR=1
  install_pty --dry-run --yes
  nocolour="$OUT"
  unset NO_COLOR
  chk_eq "NO_COLOR run exit code" 0 "$RC"
  chk "NO_COLOR=1 turns colour off on a terminal" \
    "$(has_colour "$nocolour" && echo 1 || echo 0)"

  export TERM=dumb
  install_pty --dry-run --yes
  dumb="$OUT"
  export TERM=xterm-256color
  chk_eq "TERM=dumb run exit code" 0 "$RC"
  chk "TERM=dumb turns colour off" "$(has_colour "$dumb" && echo 1 || echo 0)"

  install_notty --dry-run --yes
  piped="$OUT"
  chk_eq "piped run exit code" 0 "$RC"
  chk "a pipe never gets colour" "$(has_colour "$piped" && echo 1 || echo 0)"

  chk_eq "NO_COLOR and TERM=dumb print the same text" \
    "$(plain_text "$nocolour")" "$(plain_text "$dumb")"
  chk_eq "the piped run prints the same text" \
    "$(plain_text "$nocolour")" "$(plain_text "$piped")"
  chk_eq "colour only decorates: the words are the same" \
    "$(plain_text "$nocolour")" "$(plain_text "$colour")"

  PTY_LINES="$EMAIL
123456"
  install_pty --yes
  chk_eq "install exit code" 0 "$RC"
  local lc w
  lc=$(printf '%s%s' "$OUT" "$piped" | tr 'A-Z' 'a-z')
  for w in retry_after_days covers_well quota_exceeded roadmap; do
    chk_not_contains "nothing the user reads mentions $w" "$lc" "$w"
  done
  mock_stop
}

case_C55() { # a claude-less install writes nothing into ~/.claude/settings.json
  mock_start ok || return 1
  set_paths
  local s before
  s=$(claude_settings)
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1
  PTY_LINES="$EMAIL
123456"
  install_pty --yes --harness=codex,opencode
  chk_eq "install exit code" 0 "$RC"
  assert_installed codex opencode
  assert_onboarding_installed codex opencode
  assert_onboarding_absent claude
  chk_exists "no settings.json was created for a claude-less install" "$s" no

  fixture claude/seeded.settings.json "$s"
  before=$(sha_of "$s")
  PTY_LINES=""
  install_notty --yes --harness=codex,opencode
  chk_eq "second install exit code" 0 "$RC"
  chk_eq "a pre-existing settings.json is byte-identical" "$before" "$(sha_of "$s")"
  chk_eq "no backup of settings.json was taken" 0 "$(settings_backups | wc -l)"
  chk_eq "no hook was added" 0 "$(hook_cmds | grep -c 'cosift' || true)"
  mock_stop
}



case_C56() { # the closing offer to open a harness, which the rest of the suite suppresses
  mock_start ok || return 1
  set_paths
  # A stub on PATH ahead of the real CLI, so accepting the offer proves the exec happened
  # without handing the case an interactive agent it can never exit.
  mkdir -p "$HOME/stub"
  local real_claude
  real_claude=$(command -v claude)
  cat >"$HOME/stub/claude" <<STUB
#!/bin/sh
# Everything the installer does goes to the real CLI; only the closing launch is caught.
case "\$1" in
"set up cosift")
	printf 'STUB-CLAUDE-LAUNCHED argv=%s\n' "\$*"
	exit 0
	;;
esac
exec $real_claude "\$@"
STUB
  chmod 755 "$HOME/stub/claude"
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1

  PTY_LINES="y
$EMAIL
123456
y"
  COSIFT_TEST_ALLOW_LAUNCH=1 PATH="$HOME/stub:$PATH" install_pty --harness=claude
  chk_eq "accepting the offer exits 0" 0 "$RC"
  chk_contains "the harness was actually opened" "$OUT" "STUB-CLAUDE-LAUNCHED"
  chk_contains "it was opened with a prompt that starts setup" "$OUT" "set up cosift"
  chk_contains "and it said so first" "$OUT" "Opening Claude Code"
  assert_onboarding_installed claude
  # exec replaces the installer, so nothing of ours may survive into that session.
  chk_eq "no installer temp dir outlived the exec" "" \
    "$(find /tmp -maxdepth 1 -name 'cosift-install.*' 2>/dev/null)"

  install_notty --uninstall
  PTY_LINES="y
$EMAIL
123456
n"
  COSIFT_TEST_ALLOW_LAUNCH=1 PATH="$HOME/stub:$PATH" install_pty --harness=claude
  chk_eq "declining exits 0" 0 "$RC"
  chk_not_contains "declining opens nothing" "$OUT" "STUB-CLAUDE-LAUNCHED"
  chk_contains "declining still tells you how to start it" "$OUT" "/cosift-onboarding"

  install_notty --uninstall
  PTY_LINES="y
$EMAIL
123456"
  COSIFT_TEST_ALLOW_LAUNCH=1 PATH="$HOME/stub:$PATH" install_pty --harness=claude --no-launch
  chk_eq "--no-launch exit code" 0 "$RC"
  chk_not_contains "--no-launch opens nothing" "$OUT" "STUB-CLAUDE-LAUNCHED"

  # Accepting every default is not consent to have an application opened.
  install_notty --uninstall
  PTY_LINES="$EMAIL
123456"
  COSIFT_TEST_ALLOW_LAUNCH=1 PATH="$HOME/stub:$PATH" install_pty --yes
  chk_eq "--yes exit code" 0 "$RC"
  chk_not_contains "--yes opens nothing" "$OUT" "STUB-CLAUDE-LAUNCHED"
  mock_stop
}


case_C57() { # a migration that drops a stale key is not a reset; losing the data is
  set_paths
  local lib=/tmp/cosift-test/c57-lib.sh
  sed '$d' "$INSTALL_SH" >"$lib"          # everything but the final main "$@"

  mkdir -p "$HOME/.claude"
  cat >"$HOME/.claude.json" <<'CFG'
{"autoUpdates": true, "theme": "dark", "projects": {"/w": {"mcpServers": {"weather": {}}}}}
CFG

  # Claude Code drops keys it no longer uses when it migrates. That must not read as a reset.
  local out rc
  out=$(cd "$HOME" && sh -c '. '"$lib"'
init_tmp
claude_topkeys >"$TMPD/claude.topkeys.before"
claude_user_servers >"$TMPD/claude.servers.before"
claude_quarantine_list >"$TMPD/claude.quarantine.before"
cat >"$HOME/.claude.json" <<EOF
{"theme": "dark", "migrationVersion": 14, "projects": {"/w": {"mcpServers": {"weather": {}}}}}
EOF
claude_reset_check /tmp/backup 2>&1' ); rc=$?
  chk_eq "a dropped preference key is not treated as a reset" 0 "$rc"
  chk_eq "and it says nothing about replacing the config" "" "$out"

  # Losing projects is losing every per-directory setting and MCP server: that is a reset.
  out=$(cd "$HOME" && sh -c '. '"$lib"'
init_tmp
claude_topkeys >"$TMPD/claude.topkeys.before"
claude_user_servers >"$TMPD/claude.servers.before"
claude_quarantine_list >"$TMPD/claude.quarantine.before"
printf "{\"theme\": \"dark\"}\n" >"$HOME/.claude.json"
claude_reset_check /tmp/backup 2>&1'; ); rc=$?
  chk "losing projects is caught" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
  chk_contains "and it is reported as a replaced config" "$out" "replaced"

  # A quarantine file appearing is the unambiguous signal, whatever the keys look like.
  cat >"$HOME/.claude.json" <<'CFG'
{"theme": "dark", "projects": {"/w": {"mcpServers": {"weather": {}}}}}
CFG
  out=$(cd "$HOME" && sh -c '. '"$lib"'
init_tmp
claude_topkeys >"$TMPD/claude.topkeys.before"
claude_user_servers >"$TMPD/claude.servers.before"
claude_quarantine_list >"$TMPD/claude.quarantine.before"
mkdir -p "$HOME/.claude/backups"
: >"$HOME/.claude/backups/.claude.json.corrupted.1700000000"
claude_reset_check /tmp/backup 2>&1'); rc=$?
  chk "a .corrupted. quarantine file is caught" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
  chk_contains "and it is reported" "$out" "replaced"
}

case_C58() { # --new-account must ignore a credential the machine already has
  mock_start ok || return 1
  set_paths
  # A usable token in a harness config, of the kind recovery is built to find - including
  # one under a server name that is not ours.
  mkdir -p "$HOME/.config/opencode"
  cat >"$HOME/.config/opencode/opencode.json" <<JSON
{ "mcp": { "someone-elses-staging": { "type": "remote", "url": "$MCP_URL",
  "headers": { "Authorization": "Bearer $MINTED_TOKEN" } } } }
JSON
  mkdir -p "$HOME/work" && cd "$HOME/work" || return 1

  # Without the flag, that token is reused and no code is ever requested.
  install_notty --harness=claude --yes
  chk_eq "plain run exit code" 0 "$RC"
  chk_eq "plain run reused the credential, so no code was requested" 0 "$(nreq POST /auth/start)"

  install_notty --uninstall
  mock_stop
  mock_start ok || return 1

  # With it, the email flow runs even though a perfectly good token is sitting there.
  PTY_LINES="y
$EMAIL
123456"
  install_pty --harness=claude --new-account
  chk_eq "--new-account exit code" 0 "$RC"
  chk_eq "--new-account requested a code" 1 "$(nreq POST /auth/start)"
  chk_contains "and said it was leaving the existing one alone" "$OUT" "left alone"
  chk_not_contains "it never reported reusing a credential" "$OUT" "Reusing"

  # The credential it ignored is still exactly where it was.
  chk_contains "the other tool's credential is untouched" \
    "$(cat "$HOME/.config/opencode/opencode.json")" "$MINTED_TOKEN"

  # --dry-run reports the same intent rather than probing for a token.
  install_notty --dry-run --yes --new-account
  chk_contains "dry-run says a new account" "$OUT" "a new account"
  chk_not_contains "dry-run does not offer to reuse" "$OUT" "would be reused"
  mock_stop
}
# =====================================================================
# container entrypoint
# =====================================================================

run_container_case() {
  local id="$1"
  write_helpers
  if [ ! -f "$INSTALL_SH" ]; then
    echo "    FAIL  installer not found at $INSTALL_SH"
    echo "RESULT $id FAIL 0 1"
    return 1
  fi
  "case_$id"
  local rc=$?
  mock_stop
  if [ "$A_SKIP" -gt 0 ]; then
    echo "    ####  $A_SKIP check(s) SKIPPED -- NOT proven by this run  ####"
  fi
  if [ "$A_FAIL" -eq 0 ] && [ "$rc" -eq 0 ]; then
    echo "RESULT $id PASS $A_PASS $A_FAIL"
  else
    echo "RESULT $id FAIL $A_PASS $A_FAIL"
  fi
  [ "$A_FAIL" -eq 0 ] && [ "$rc" -eq 0 ]
}

# =====================================================================
# host entrypoint
# =====================================================================

host_build() {
  local dir="$1"
  echo "==> building $IMAGE"
  if ! docker build -f "$dir/Dockerfile" -t "$IMAGE" "$dir"; then
    echo "!! image build failed" >&2
    return 1
  fi
}

host_banner() {
  local prov stubbed=""
  prov=$(docker run --rm --entrypoint cat "$IMAGE" \
         /opt/cosift-test/harness-provenance.env 2>/dev/null)
  local h
  for h in CLAUDE CODEX OPENCODE; do
    case "$prov" in
      *"${h}_PROVENANCE=stub"*) stubbed="$stubbed $(printf '%s' "$h" | tr 'A-Z' 'a-z')" ;;
    esac
  done
  if [ -n "$stubbed" ]; then
    echo "################################################################"
    echo "##  WARNING: STUBBED HARNESS CLIs -- RESULTS ARE NOT REAL     ##"
    echo "##  stubbed:$stubbed"
    echo "##  These ran against tests/fixtures/stubs/harness-stub.py,    ##"
    echo "##  not the vendor CLI. Header syntax, config shape and write  ##"
    echo "##  semantics are APPROXIMATED. Do not ship on this run.       ##"
    echo "################################################################"
  else
    echo "==> harness CLIs: all three are the REAL vendor CLIs"
  fi
  printf '%s\n' "$prov" | sed 's/^/    /'
}

host_run_case() { # host_run_case <id> <user> <outfile>
  local id="$1" user="$2" out="$3"
  local uarg="tester" home="/home/tester"
  if [ "$user" = root ]; then uarg="0:0"; home="/home/tester"; fi
  timeout "$CASE_TIMEOUT" docker run --rm --network none \
    --user "$uarg" \
    -e HOME="$home" \
    -e "COSIFT_INSTALL_SH=${COSIFT_INSTALL_SH:-/work/install.sh}" \
    -v "$REPO:/work:ro" \
    -w "$home" \
    "$IMAGE" bash /work/tests/run.sh --container-case "$id" >"$out" 2>&1
}

main_host() {
  local jobs=4 build=1
  local -a want=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -j) jobs="$2"; shift 2 ;;
      -j*) jobs="${1#-j}"; shift ;;
      --no-build) build=0; shift ;;
      --list) printf '%s\n' "${CASE_TABLE[@]}" | tr '|' ' '; return 0 ;;
      -h|--help)
        echo "usage: tests/run.sh [-j N] [--no-build] [--list] [CASE_ID ...]"
        return 0 ;;
      *) want+=("$1"); shift ;;
    esac
  done

  if [ ! -f "$REPO/install.sh" ]; then
    echo "!! $REPO/install.sh does not exist yet -- nothing to test." >&2
    echo "   (set COSIFT_INSTALL_SH to point elsewhere)" >&2
    return 1
  fi

  local -a selected=()
  local spec id
  for spec in "${CASE_TABLE[@]}"; do
    id="${spec%%|*}"
    if [ "${#want[@]}" -eq 0 ]; then
      selected+=("$spec")
    else
      local w
      for w in "${want[@]}"; do
        [ "$w" = "$id" ] && selected+=("$spec")
      done
    fi
  done
  if [ "${#selected[@]}" -eq 0 ]; then
    echo "no matching cases" >&2
    return 2
  fi

  [ "$build" -eq 1 ] && { host_build "$REPO/tests" || return 1; }
  host_banner
  echo "==> running ${#selected[@]} case(s), -j$jobs"
  echo

  HOST_TMP=$(mktemp -d) || return 1
  trap 'rm -rf "$HOST_TMP"' EXIT
  local tmp="$HOST_TMP"

  local -a pids=() outs=() ids=() descs=()
  local user desc
  for spec in "${selected[@]}"; do
    id="${spec%%|*}"
    desc="${spec#*|}"; user="${desc##*|}"; desc="${desc%|*}"
    while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do sleep 0.2; done
    host_run_case "$id" "$user" "$tmp/$id.out" &
    pids+=($!); outs+=("$tmp/$id.out"); ids+=("$id"); descs+=("$desc")
  done

  local pass=0 fail=0 i n done_n=0
  n=${#pids[@]}
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}"
    done_n=$((done_n + 1))
    local body verdict
    body=$(cat "${outs[$i]}" 2>/dev/null)
    verdict=$(printf '%s\n' "$body" | grep '^RESULT ' | tail -1)
    echo "--- ${ids[$i]}  ${descs[$i]}"
    printf '%s\n' "$body" | grep -v '^RESULT ' | sed '/^$/d'
    if [ "${verdict#RESULT ${ids[$i]} PASS}" != "$verdict" ]; then
      echo "  PASS ${ids[$i]}  [$done_n/$n]"
      pass=$((pass + 1))
    else
      echo "  FAIL ${ids[$i]}  [$done_n/$n]"
      fail=$((fail + 1))
    fi
    echo
  done

  echo "SUMMARY: $pass passed, $fail failed, of $n case(s)"
  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------
if [ "${1:-}" = "--container-case" ]; then
  run_container_case "$2"
  exit $?
fi

SELF=$(cd "$(dirname "$0")" && pwd)
REPO="${COSIFT_REPO:-$(cd "$SELF/.." && pwd)}"
main_host "$@"
