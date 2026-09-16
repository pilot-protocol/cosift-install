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
  "C27|default-endpoints-are-not-run-app|tester"
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
)

# =====================================================================
# container-side helpers
# =====================================================================

A_PASS=0
A_FAIL=0

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


def state_check(path, csv_harnesses, version_hint):
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


CMDS = {
    "manifest": manifest,
    "count-req": count_req,
    "req-header": req_header,
    "req-bodies": req_bodies,
    "all-paths": all_paths,
    "state-check": state_check,
    "claude-entry": claude_entry,
    "claude-names": claude_names,
    "toml-entry": toml_entry,
    "toml-names": toml_names,
    "jsonc-entry": jsonc_entry,
    "jsonc-names": jsonc_names,
    "jsonc-valid": jsonc_valid,
    "jsonc-topkeys": jsonc_topkeys,
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
  OUT=$(COSIFT_AUTH_BASE="$AUTH_BASE" COSIFT_MCP_URL="$MCP_URL" \
        python3 "$PTY" "$lf" 1.1 "${PTY_TOTAL:-150}" bash -c "$inner" 2>&1)
  RC=$?
}

install_notty() {
  OUT=$(COSIFT_AUTH_BASE="$AUTH_BASE" COSIFT_MCP_URL="$MCP_URL" \
        timeout 90 sh "$INSTALL_SH" "$@" </dev/null 2>&1)
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
    "$(python3 "$TH" state-check "$(state_path)" "claude,codex,opencode" "$vers")"
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
  PTY_LINES="$EMAIL
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
  PTY_LINES="$EMAIL
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
       "claude,codex" "$(installer_version)")"
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
  chk_not_contains "--dry-run never shows a *.run.app URL" "$OUT" "run.app"
  chk_contains "default MCP URL is the stable hostname" "$OUT" \
    "cosift-mcp.pilotprotocol.network/v1/mcp"
  install_split --help
  chk_not_contains "--help never shows a *.run.app URL" "$OUT" "run.app"
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
  PTY_LINES="$EMAIL
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
  PTY_LINES="$EMAIL
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
  PTY_LINES="$EMAIL
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
  chk_matches "the summary says a file mode had to be tightened" "$OUT" \
    "tighten|world-readable|group-readable|too permissive"
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

  PTY_LINES="$EMAIL
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
