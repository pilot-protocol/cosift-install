#!/bin/sh
# cosift-install - register the Cosift remote MCP server with your AI harnesses.
#
# WHAT IT DOES
#   Adds a streamable-HTTP MCP server named "cosift" to every harness you select
#   (Claude Code, OpenAI Codex CLI, opencode), authenticated by a static header
#   "Authorization: Bearer ck_<keyid>_<secret>".  A token is either recovered from
#   a harness config you already have, or minted through an email + 6-digit-code
#   flow against the Cosift auth service.
#
# WHAT IT WRITES
#   claude    ~/.claude.json            (via `claude mcp add --scope user`, never by hand)
#   codex     ${CODEX_HOME:-~/.codex}/config.toml   (marker-delimited block, appended)
#   opencode  ${XDG_CONFIG_HOME:-~/.config}/opencode/opencode.json[c]  (via `opencode mcp add`)
#   state     ${XDG_CONFIG_HOME:-~/.config}/cosift/state.json          (mode 0600)
#   Every file touched is copied to <path>.cosift-backup-<UTC timestamp> first.
#
# THESE FILES THEN HOLD A LIVE CREDENTIAL.  Treat them like a password store.
#
# HOW TO UNDO
#   Re-run with --uninstall: the cosift entry is removed from each harness and the
#   state file is deleted.  Backups are left in place.  Uninstalling does NOT revoke
#   the token server-side - revoke it from your Cosift account.
#
# USAGE
#   curl -fsSL <installer-url> | sh
#   curl -fsSL <installer-url> | sh -s -- --dry-run
#   sh install.sh --harness=claude,codex --yes
#
# POSIX sh only (this runs under dash via curl | sh).  No bashisms.

VERSION="0.1.0"

umask 077

# zsh does not word-split unquoted parameters, which collapses our harness lists.
if [ -n "${ZSH_VERSION:-}" ]; then
	emulate sh 2>/dev/null || :
	setopt shwordsplit 2>/dev/null || :
fi

# ---------------------------------------------------------------- configuration

COSIFT_AUTH_BASE="${COSIFT_AUTH_BASE:-https://cosift-auth.pilotprotocol.network}"
COSIFT_MCP_URL="${COSIFT_MCP_URL:-https://cosift-mcp.pilotprotocol.network/v1/mcp}"
COSIFT_EXTRA_HEADER="${COSIFT_EXTRA_HEADER:-}"

MCP_PROTOCOL_VERSION="2025-06-18"
HTTP_TIMEOUT=30
VERIFY_MAX_ATTEMPTS=5
INFRA_MAX_RETRIES=3

CLAUDE_JSON="$HOME/.claude.json"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
CODEX_CONFIG="$CODEX_HOME_DIR/config.toml"
# opencode uses ~/.config on macOS too - it does not follow ~/Library.
OPENCODE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cosift"
STATE_FILE="$STATE_DIR/state.json"

CODEX_MARK_OPEN="# >>> cosift (managed by cosift-install — do not edit)"
CODEX_MARK_CLOSE="# <<< cosift"

TOKEN_RE='ck_[0-9a-z]+_[A-Z2-7]{39}'

NL='
'
CR=$(printf '\r')

OPT_DRY_RUN=0
OPT_UNINSTALL=0
OPT_YES=0
OPT_HARNESS=""

TOKEN=""
ACCOUNT_UID=""
DETECTED=""
SELECTED=""
CONFIGURED=""
TMPD=""
BACKUP_PATH=""

EX_OK=0
EX_USAGE=2
EX_PREFLIGHT=3
EX_AUTH=4
EX_HARNESS=5
EX_NOTTY=6

# --------------------------------------------------------------------- helpers

say()  { printf '%s\n' "$*"; }
step() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
err()  { printf 'error: %s\n' "$*" >&2; }

die() {
	_code=$1
	shift
	err "$*"
	exit "$_code"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Anything captured from another tool may echo our argv back at us.
redact() { sed -e 's/ck_[0-9A-Za-z]*_[0-9A-Za-z]*/ck_[redacted]/g'; }

token_display() { printf '%.8s...' "$1"; }

now_stamp()  { date -u +%Y%m%dT%H%M%SZ; }
now_rfc3339() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# $2 is an unquoted word list on purpose - these lists are internal and space-free.
in_list() {
	_needle=$1
	shift
	for _item in $*; do
		if [ "$_item" = "$_needle" ]; then return 0; fi
	done
	return 1
}

list_add() {
	if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s %s' "$1" "$2"; fi
}

init_tmp() {
	TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t cosift)
	if [ -z "$TMPD" ] || [ ! -d "$TMPD" ]; then
		die "$EX_PREFLIGHT" "could not create a temporary directory"
	fi
	# --dry-run promises nothing under $HOME, which a $HOME-rooted TMPDIR would break.
	case "$TMPD" in
	"$HOME"/*)
		if [ "$OPT_DRY_RUN" -eq 1 ]; then
			rmdir "$TMPD" 2>/dev/null
			TMPD=$(TMPDIR=/tmp mktemp -d 2>/dev/null || TMPDIR=/tmp mktemp -d -t cosift)
			if [ -z "$TMPD" ] || [ ! -d "$TMPD" ]; then
				die "$EX_PREFLIGHT" "could not create a temporary directory outside $HOME"
			fi
		fi
		;;
	esac
	chmod 700 "$TMPD" 2>/dev/null
}

cleanup() {
	if [ -n "$TMPD" ] && [ -d "$TMPD" ]; then
		rm -rf "$TMPD"
	fi
	TMPD=""
}

trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Extracts a top-level string field from a tiny machine-generated JSON body on stdin.
# Scans with string/escape awareness so a field name occurring inside another value
# cannot be mistaken for a key.
json_str_field() {
	awk -v want="$1" '
	{ B = B $0 }
	END {
		N = length(B); i = 1; depth = 0
		while (i <= N) {
			c = substr(B, i, 1)
			if (c == "\"") {
				s = ""; i++
				while (i <= N) {
					ch = substr(B, i, 1)
					if (ch == "\\") { s = s substr(B, i, 2); i += 2; continue }
					if (ch == "\"") { i++; break }
					s = s ch; i++
				}
				j = i
				while (j <= N && substr(B, j, 1) ~ /[ \t\r\n]/) j++
				if (depth == 1 && substr(B, j, 1) == ":") {
					i = j + 1
					while (i <= N && substr(B, i, 1) ~ /[ \t\r\n]/) i++
					if (substr(B, i, 1) == "\"") {
						v = ""; i++
						while (i <= N) {
							ch = substr(B, i, 1)
							if (ch == "\\") { v = v substr(B, i, 2); i += 2; continue }
							if (ch == "\"") { i++; break }
							v = v ch; i++
						}
						if (s == want) {
							gsub(/\\\//, "/", v)
							gsub(/\\"/, "\"", v)
							gsub(/\\n/, " ", v)
							gsub(/\\\\/, "\\", v)
							print v
							exit 0
						}
					}
				}
				continue
			}
			if (c == "{" || c == "[") depth++
			else if (c == "}" || c == "]") depth--
			i++
		}
	}'
}

# Structural well-formedness only (balanced, correctly nested, strings closed) - enough
# to tell a truncated config from a healthy one without a JSON parser.
json_wellformed() {
	awk '
	{ B = B $0 "\n" }
	END {
		N = length(B); i = 1; depth = 0; seen = 0; stack = ""
		while (i <= N) {
			c = substr(B, i, 1)
			if (c == "\"") {
				i++; closed = 0
				while (i <= N) {
					ch = substr(B, i, 1)
					if (ch == "\\") { i += 2; continue }
					if (ch == "\"") { i++; closed = 1; break }
					i++
				}
				if (!closed) exit 1
				continue
			}
			if (c == "{" || c == "[") {
				depth++; seen = 1; stack = stack c; i++
				continue
			}
			if (c == "}" || c == "]") {
				if (depth == 0) exit 1
				o = substr(stack, depth, 1)
				if ((c == "}" && o != "{") || (c == "]" && o != "[")) exit 1
				stack = substr(stack, 1, depth - 1); depth--; i++
				continue
			}
			i++
		}
		if (depth != 0 || seen != 1) exit 1
		exit 0
	}' "$1"
}

JSON_PARSER=""
detect_json_parser() {
	if [ -n "$JSON_PARSER" ]; then return 0; fi
	# Probe on a known-good document first, so "no parser / broken parser" can never be
	# mistaken for "your config is corrupt".
	if have_cmd python3 && python3 -c 'import json; json.loads("{}")' >/dev/null 2>&1; then
		JSON_PARSER=python3
	elif have_cmd node && node -e 'JSON.parse("{}")' >/dev/null 2>&1; then
		JSON_PARSER=node
	else
		JSON_PARSER=awk
	fi
	return 0
}

# json_wellformed only catches truncation, while Claude Code quarantines anything a
# real parser rejects; use a real parser whenever the machine has one.
json_parses() {
	detect_json_parser
	case "$JSON_PARSER" in
	python3)
		python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1
		;;
	node)
		node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1" \
			>/dev/null 2>&1
		;;
	*)
		json_wellformed "$1"
		;;
	esac
}

# json_scan <mode> <want> <file>. topkeys: print the top-level key names. servers:
# print the key names of the top-level "mcpServers" object. entry: print the raw text
# of mcpServers.<want>. Exit 1 when the shape asked for is not present.
json_scan() {
	awk -v MODE="$1" -v WANT="$2" '
	function skipws(p,   c) {
		while (p <= N) {
			c = substr(B, p, 1)
			if (c == " " || c == "\t" || c == "\r" || c == "\n") { p++; continue }
			break
		}
		return p
	}
	function endstr(p,   c) {
		p++
		while (p <= N) {
			c = substr(B, p, 1)
			if (c == "\\") { p += 2; continue }
			if (c == "\"") return p + 1
			p++
		}
		return 0
	}
	function endval(p,   c, d) {
		c = substr(B, p, 1)
		if (c == "\"") return endstr(p)
		if (c == "{" || c == "[") {
			d = 0
			while (p <= N) {
				c = substr(B, p, 1)
				if (c == "\"") { p = endstr(p); if (p == 0) return 0; continue }
				if (c == "{" || c == "[") { d++; p++; continue }
				if (c == "}" || c == "]") { d--; p++; if (d == 0) return p; continue }
				p++
			}
			return 0
		}
		while (p <= N) {
			c = substr(B, p, 1)
			if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\r" || c == "\n") break
			p++
		}
		return p
	}
	function scan(objp, k,   p, c, ks, ke, key, vs, ve) {
		F_vs = 0; F_ve = 0
		p = skipws(objp + 1)
		while (p <= N) {
			c = substr(B, p, 1)
			if (c == "}") return 0
			if (c != "\"") return -1
			ks = p
			ke = endstr(p)
			if (ke == 0) return -1
			key = substr(B, ks + 1, ke - ks - 2)
			p = skipws(ke)
			if (substr(B, p, 1) != ":") return -1
			vs = skipws(p + 1)
			ve = endval(vs)
			if (ve == 0) return -1
			if (LISTING) print key
			else if (key == k) { F_vs = vs; F_ve = ve; return 1 }
			p = skipws(ve)
			c = substr(B, p, 1)
			if (c == ",") { p = skipws(p + 1); continue }
			if (c == "}") return 0
			return -1
		}
		return -1
	}
	{ B = B $0 "\n" }
	END {
		N = length(B)
		p = skipws(1)
		if (substr(B, p, 1) != "{") exit 1
		if (MODE == "topkeys") { LISTING = 1; if (scan(p, "") < 0) exit 1; exit 0 }
		if (scan(p, "mcpServers") != 1) exit 1
		q = F_vs
		if (substr(B, q, 1) != "{") exit 1
		if (MODE == "servers") { LISTING = 1; if (scan(q, "") < 0) exit 1; exit 0 }
		if (scan(q, WANT) != 1) exit 1
		printf "%s", substr(B, F_vs, F_ve - F_vs)
		exit 0
	}' "$3"
}

# Compares stdin lines against a secret without ever putting it in an argv.
stdin_has_line() {
	while IFS= read -r _sl; do
		if [ "$_sl" = "$1" ]; then return 0; fi
	done
	return 1
}

# Reads are from /dev/tty, never stdin: under `curl | sh` stdin is the script itself.
tty_usable() {
	if [ ! -e /dev/tty ]; then return 1; fi
	(exec 3</dev/tty) 2>/dev/null
}

require_tty() {
	if ! tty_usable; then
		err "this step needs to ask you a question, but no terminal is available."
		err "download the script and run it directly instead:"
		err "  curl -fsSL <installer-url> -o cosift-install.sh && sh cosift-install.sh"
		exit "$EX_NOTTY"
	fi
}

TTY_REPLY=""
tty_ask() {
	TTY_REPLY=""
	printf '%s' "$1" >/dev/tty
	if ! IFS= read -r TTY_REPLY </dev/tty; then
		printf '\n' >/dev/tty
		return 1
	fi
	return 0
}

# Group/other bits of the mode string, without depending on stat(1).
file_is_exposed() {
	_perm=$(ls -ld "$1" 2>/dev/null | cut -c5-10)
	case "$_perm" in
	"------") return 1 ;;
	"") return 1 ;;
	esac
	return 0
}

TIGHTENED=""
# Every file we write the token into must end up owner-only, including a config that
# already existed with a laxer mode (cp preserves the destination's mode).
harden_mode() {
	if [ ! -f "$1" ]; then return 0; fi
	if ! file_is_exposed "$1"; then return 0; fi
	chmod 600 "$1" 2>/dev/null
	if file_is_exposed "$1"; then
		warn "could not tighten the permissions of $1; it holds a live credential."
		return 1
	fi
	if [ -z "$TIGHTENED" ]; then
		TIGHTENED=$1
	else
		TIGHTENED="$TIGHTENED$NL$1"
	fi
	return 0
}

backup_file() {
	BACKUP_PATH=""
	if [ ! -f "$1" ]; then return 0; fi
	_base="$1.cosift-backup-$(now_stamp)"
	_bak=$_base
	_n=1
	while [ -e "$_bak" ]; do
		_bak="$_base.$_n"
		_n=$((_n + 1))
	done
	if ! cp "$1" "$_bak"; then
		err "could not back up $1"
		return 1
	fi
	chmod 600 "$_bak" 2>/dev/null
	harden_mode "$_bak"
	BACKUP_PATH=$_bak
	return 0
}

# One backup per file per run, taken before anything that could touch it. Re-running
# must not bury the pre-Cosift copy under a second, already-configured one.
ensure_backup() {
	BACKUP_PATH=""
	if [ ! -f "$1" ]; then return 0; fi
	_idx="$TMPD/backups.idx"
	if [ -f "$_idx" ]; then
		while IFS='	' read -r _bp _bb; do
			if [ "$_bp" = "$1" ] && [ -f "$_bb" ]; then
				BACKUP_PATH=$_bb
				return 0
			fi
		done <"$_idx"
	fi
	if ! backup_file "$1"; then return 1; fi
	printf '%s\t%s\n' "$1" "$BACKUP_PATH" >>"$_idx"
	return 0
}

restore_backup() {
	if [ -n "$2" ] && [ -f "$2" ]; then
		cp "$2" "$1" 2>/dev/null && return 0
	fi
	return 1
}

# ------------------------------------------------------------------------ http

# Curl reads headers from a config file so the bearer token never lands in argv,
# where any local user could read it out of `ps`.
mk_header_file() {
	_hf="$TMPD/hdr.$$.$1"
	: >"$_hf"
	chmod 600 "$_hf" 2>/dev/null
	printf '%s\n' "$_hf"
}

write_common_headers() {
	printf 'header = "Content-Type: application/json"\n' >>"$1"
	if [ -n "$COSIFT_EXTRA_HEADER" ]; then
		printf 'header = "%s"\n' "$COSIFT_EXTRA_HEADER" >>"$1"
	fi
}

auth_header_file() {
	_f=$(mk_header_file auth)
	printf 'header = "Accept: application/json"\n' >>"$_f"
	write_common_headers "$_f"
	printf '%s\n' "$_f"
}

mcp_header_file() {
	_f=$(mk_header_file mcp)
	printf 'header = "Authorization: Bearer %s"\n' "$1" >>"$_f"
	printf 'header = "Accept: application/json, text/event-stream"\n' >>"$_f"
	write_common_headers "$_f"
	printf '%s\n' "$_f"
}

# http_post <url> <body-file> <out-file> <header-file> -> prints the HTTP status
http_post() {
	# -q must come first: it is what stops ~/.curlrc from rewriting a credential-bearing
	# request (proxy, insecure, extra output files).
	_status=$(curl -q -sS -X POST -K "$4" --data-binary @"$2" \
		-o "$3" -w '%{http_code}' --max-time "$HTTP_TIMEOUT" "$1" \
		2>"$TMPD/curl.err")
	if [ -z "$_status" ]; then _status="000"; fi
	printf '%s\n' "$_status"
}

http_hint() {
	if [ -s "$TMPD/curl.err" ]; then
		sed -e 's/^/  /' "$TMPD/curl.err" | redact >&2
	fi
}

# ------------------------------------------------------------------ mcp verify

# mcp_initialize <token> -> prints the HTTP status of a JSON-RPC initialize call
mcp_initialize() {
	_body="$TMPD/mcp-init.json"
	printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"%s","capabilities":{},"clientInfo":{"name":"cosift-install","version":"%s"}}}' \
		"$MCP_PROTOCOL_VERSION" "$VERSION" >"$_body"
	_hf=$(mcp_header_file "$1")
	_st=$(http_post "$COSIFT_MCP_URL" "$_body" "$TMPD/mcp-init.out" "$_hf")
	rm -f "$_hf"
	printf '%s\n' "$_st"
}

mcp_explain() {
	case "$1" in
	200) say "The MCP endpoint accepted the credential." ;;
	401)
		err "the MCP server rejected the token (unknown or revoked)."
		err "mint a fresh one by re-running the installer; if it keeps failing, the key was revoked."
		;;
	403)
		err "this account is suspended. A new token will not help."
		err "contact Cosift support before retrying."
		;;
	421)
		err "the MCP server refused the request host (DNS-rebinding protection)."
		err "the hostname in COSIFT_MCP_URL is not in the server allow-list:"
		err "  $COSIFT_MCP_URL"
		err "use the documented URL, or ask for the hostname to be allow-listed."
		;;
	429)
		err "rate limited by the MCP server. Wait a few minutes and try again."
		;;
	503)
		err "the Cosift backend is temporarily unavailable (retry in about 5 seconds)."
		err "this is infrastructure, not a verdict on your credential."
		;;
	000)
		err "could not reach $COSIFT_MCP_URL (network, DNS or TLS failure)."
		http_hint
		;;
	*)
		err "unexpected response from the MCP server (HTTP $1)."
		;;
	esac
}

# ------------------------------------------------------------------ auth flow

auth_start() {
	REQUEST_ID=""
	_body="$TMPD/auth-start.json"
	printf '{"email":"%s"}' "$1" >"$_body"
	_hf=$(auth_header_file)
	say "Requesting a login code (this takes a moment)..."
	_st=$(http_post "$COSIFT_AUTH_BASE/auth/start" "$_body" "$TMPD/auth-start.out" "$_hf")
	rm -f "$_hf"
	if [ "$_st" = "000" ]; then
		err "could not reach $COSIFT_AUTH_BASE (network, DNS or TLS failure)."
		http_hint
		return 1
	fi
	case "$_st" in
	200) ;;
	429)
		err "rate limited before the code could be sent. The service sends no"
		err "Retry-After, so wait a few minutes and re-run. Note the cap: 3 codes"
		err "per address per hour."
		return 1
		;;
	503)
		err "the auth service is temporarily unavailable. This is infrastructure,"
		err "not a verdict on your address - try again in a few minutes."
		return 1
		;;
	*)
		err "the auth service answered HTTP $_st, which it should never do for this call."
		return 1
		;;
	esac
	REQUEST_ID=$(json_str_field request_id <"$TMPD/auth-start.out")
	if [ -z "$REQUEST_ID" ]; then
		err "the auth service response did not contain a request id."
		return 1
	fi
	# The service answers 200 for unknown addresses, malformed bodies and quota
	# refusals alike, so delivery must never be stated as a fact.
	say "If that address can be registered, a code is on its way. It expires shortly."
	return 0
}

no_code_help() {
	say ""
	say "No code yet? A few things to know:"
	say "  - Delivery is not confirmed by the service, so an unknown or blocked"
	say "    address looks exactly like a delivered one from here."
	say "  - Check the spam folder."
	say "  - There is a cap of 3 codes per address per hour. If you have already"
	say "    asked several times, wait an hour before requesting another."
	say "  - Press Enter on an empty code to see this message again, or Ctrl-C to stop."
	say ""
}

auth_verify_loop() {
	_attempts=0
	_infra=0
	_hf=$(auth_header_file)
	while [ "$_attempts" -lt "$VERIFY_MAX_ATTEMPTS" ]; do
		if ! tty_ask "6-digit code: "; then
			rm -f "$_hf"
			err "no code entered."
			return 1
		fi
		_code=$TTY_REPLY
		if [ -z "$_code" ]; then
			no_code_help
			continue
		fi
		if ! printf '%s' "$_code" | grep -Eq '^[0-9]{6}$'; then
			say "That does not look like a 6-digit code. Try again."
			continue
		fi
		_attempts=$((_attempts + 1))
		_body="$TMPD/auth-verify.json"
		printf '{"request_id":"%s","code":"%s"}' "$REQUEST_ID" "$_code" >"$_body"
		_st=$(http_post "$COSIFT_AUTH_BASE/auth/verify" "$_body" "$TMPD/auth-verify.out" "$_hf")
		case "$_st" in
		200)
			TOKEN=$(json_str_field token <"$TMPD/auth-verify.out")
			ACCOUNT_UID=$(json_str_field account_uid <"$TMPD/auth-verify.out")
			rm -f "$_hf" "$TMPD/auth-verify.out"
			if [ -z "$TOKEN" ]; then
				err "the auth service returned success but no token."
				return 1
			fi
			say "Code accepted. Token $(token_display "$TOKEN") obtained."
			return 0
			;;
		401)
			_left=$((VERIFY_MAX_ATTEMPTS - _attempts))
			err "that code was not accepted. A wrong code and an expired code look"
			err "identical from here, and so does a code superseded by a newer request."
			if [ "$_left" -gt 0 ]; then
				say "Attempts left before the server stops accepting any code: $_left"
			fi
			;;
		403)
			rm -f "$_hf"
			err "this account is suspended. A new token will not help; stopping."
			return 1
			;;
		429)
			_infra=$((_infra + 1))
			_attempts=$((_attempts - 1))
			if [ "$_infra" -ge "$INFRA_MAX_RETRIES" ]; then
				rm -f "$_hf"
				err "still rate limited after $_infra tries. Wait a few minutes and re-run."
				return 1
			fi
			_wait=$((_infra * 10))
			err "rate limited. The service sends no Retry-After, so this is a guess:"
			err "backing off for ${_wait}s, then you can enter the code again."
			sleep "$_wait"
			;;
		503)
			_infra=$((_infra + 1))
			_attempts=$((_attempts - 1))
			if [ "$_infra" -ge "$INFRA_MAX_RETRIES" ]; then
				rm -f "$_hf"
				err "the auth service is still unavailable. This is infrastructure, not your"
				err "code. Try again in a few minutes."
				return 1
			fi
			err "the auth service is temporarily unavailable (this is not a verdict on"
			err "your code). Retrying in 5s - the same code should still work."
			sleep 5
			;;
		000)
			rm -f "$_hf"
			err "could not reach $COSIFT_AUTH_BASE (network, DNS or TLS failure)."
			http_hint
			return 1
			;;
		*)
			rm -f "$_hf"
			err "unexpected response from the auth service (HTTP $_st)."
			return 1
			;;
		esac
	done
	rm -f "$_hf"
	err "out of attempts. The server stops accepting codes for this request after"
	err "$VERIFY_MAX_ATTEMPTS tries - re-run the installer to request a new one."
	return 1
}

email_flow() {
	require_tty
	say ""
	say "No usable Cosift credential was found, so we need to mint one."
	while :; do
		if ! tty_ask "Email address: "; then
			err "no email address entered."
			return 1
		fi
		_email=$TTY_REPLY
		if printf '%s' "$_email" | grep -Eq '^[^[:space:]"\\@]+@[^[:space:]"\\@]+\.[^[:space:]"\\@]+$'; then
			break
		fi
		say "That does not look like an email address. Try again."
	done
	if ! auth_start "$_email"; then return 1; fi
	no_code_help
	auth_verify_loop
}

# -------------------------------------------------------- harness: claude code

claude_detect() { have_cmd claude; }

claude_json_ok() {
	if [ ! -s "$CLAUDE_JSON" ]; then return 0; fi
	json_parses "$CLAUDE_JSON"
}

claude_refuse_malformed() {
	err "$CLAUDE_JSON is not well-formed JSON, so we will not touch it."
	err "Claude Code quarantines a config it cannot parse and starts a fresh one,"
	err "which would lose every setting in that file. Repair it first - there may"
	err "be a copy under $HOME/.claude/backups - then re-run."
}

# Deliberately does not probe with the CLI: `claude mcp get` is a write that can
# quarantine and reset a config we have not backed up yet.
claude_is_configured() {
	if [ -f "$CLAUDE_JSON" ] && grep -q '"cosift"' "$CLAUDE_JSON"; then
		return 0
	fi
	return 1
}

claude_user_entry() {
	if [ ! -f "$CLAUDE_JSON" ]; then return 1; fi
	json_scan entry cosift "$CLAUDE_JSON" 2>/dev/null
}

# Our entry, in our scope. A cosift entry under projects["<dir>"] is a different scope
# that we do not manage, and must not be read as "already installed".
claude_up_to_date() {
	_e=$(claude_user_entry) || return 1
	if [ -z "$_e" ]; then return 1; fi
	case "$_e" in
	*"$COSIFT_MCP_URL"*) ;;
	*) return 1 ;;
	esac
	case "$_e" in
	*"Bearer $1"*) return 0 ;;
	esac
	return 1
}

# Directories whose projects["<dir>"].mcpServers holds a cosift entry. `claude mcp add`
# without --scope user lands there, and such an entry holds a live token that
# --scope user removal never touches.
claude_project_dirs() {
	if [ ! -f "$CLAUDE_JSON" ]; then return 0; fi
	detect_json_parser
	case "$JSON_PARSER" in
	python3)
		python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for k, v in (d.get("projects") or {}).items():
    if isinstance(v, dict) and "cosift" in (v.get("mcpServers") or {}):
        print(k)' "$CLAUDE_JSON" 2>/dev/null
		;;
	node)
		node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
for (const [k,v] of Object.entries(d.projects||{}))
  if (v && v.mcpServers && v.mcpServers.cosift) console.log(k);' "$CLAUDE_JSON" 2>/dev/null
		;;
	esac
}

claude_topkeys() {
	if [ ! -f "$CLAUDE_JSON" ]; then return 0; fi
	json_scan topkeys "" "$CLAUDE_JSON" 2>/dev/null
}

claude_user_servers() {
	if [ ! -f "$CLAUDE_JSON" ]; then return 0; fi
	json_scan servers "" "$CLAUDE_JSON" 2>/dev/null
}

# Claude Code answers a config it cannot parse by moving it aside and writing a fresh
# minimal one; the tell is that keys the user had are simply gone.
claude_reset_check() {
	claude_topkeys >"$TMPD/claude.topkeys.after"
	claude_user_servers >"$TMPD/claude.servers.after"
	_lost=""
	while IFS= read -r _k; do
		if [ -z "$_k" ]; then continue; fi
		if ! grep -Fqx -e "$_k" "$TMPD/claude.topkeys.after"; then _lost=$_k; break; fi
	done <"$TMPD/claude.topkeys.before"
	if [ -z "$_lost" ]; then
		while IFS= read -r _k; do
			if [ -z "$_k" ]; then continue; fi
			if ! grep -Fqx -e "$_k" "$TMPD/claude.servers.after"; then
				_lost="mcpServers.$_k"
				break
			fi
		done <"$TMPD/claude.servers.before"
	fi
	if [ -z "$_lost" ]; then return 0; fi
	err "Claude Code replaced $CLAUDE_JSON with a fresh config: '$_lost' is gone."
	err "that is what it does when it cannot parse the file, and it keeps its own copy"
	err "of the original under $HOME/.claude/backups/ (.claude.json.corrupted.*)."
	if restore_backup "$CLAUDE_JSON" "$1"; then
		err "we restored our pre-run backup over it: $1"
	else
		err "we could NOT restore our backup ($1); copy it back by hand."
	fi
	err "repair the file from either copy before re-running."
	return 1
}

claude_recover_token() {
	if [ -f "$CLAUDE_JSON" ]; then
		grep -Eo "$TOKEN_RE" "$CLAUDE_JSON" 2>/dev/null
	fi
}

claude_add() {
	_tok=$1
	if ! have_cmd claude; then
		err "claude is not on PATH, so its config cannot be written safely."
		err "install Claude Code and re-run, or add the server manually:"
		claude_manual_help
		return 1
	fi
	if ! claude_json_ok; then
		claude_refuse_malformed
		return 1
	fi
	# Backup precedes every CLI call: `claude mcp list` itself rewrites this file, and a
	# config it refuses to parse is quarantined and replaced before we ever see it.
	if ! ensure_backup "$CLAUDE_JSON"; then return 1; fi
	_bak=$BACKUP_PATH
	claude_topkeys >"$TMPD/claude.topkeys.before"
	claude_user_servers >"$TMPD/claude.servers.before"
	if claude_is_configured; then
		claude mcp remove cosift --scope user >/dev/null 2>&1
	fi
	# `claude mcp add --header` puts the token in argv; unavoidable for this CLI and
	# accepted only here. --scope user is mandatory: the default "local" scope binds
	# the server to projects["<cwd>"], i.e. whatever directory the installer ran in.
	if [ -n "$COSIFT_EXTRA_HEADER" ]; then
		claude mcp add --transport http --scope user cosift "$COSIFT_MCP_URL" \
			--header "Authorization: Bearer $_tok" \
			--header "$COSIFT_EXTRA_HEADER" >"$TMPD/claude.add" 2>&1
		_rc=$?
	else
		claude mcp add --transport http --scope user cosift "$COSIFT_MCP_URL" \
			--header "Authorization: Bearer $_tok" >"$TMPD/claude.add" 2>&1
		_rc=$?
	fi
	if [ "$_rc" -ne 0 ]; then
		if ! claude_reset_check "$_bak"; then return 1; fi
		err "claude mcp add failed:"
		redact <"$TMPD/claude.add" >&2
		return 1
	fi
	if ! claude_reset_check "$_bak"; then return 1; fi
	if [ -z "$(claude_user_entry)" ]; then
		err "claude reported success but cosift is not in the user scope of $CLAUDE_JSON."
		return 1
	fi
	harden_mode "$CLAUDE_JSON"
	return 0
}

claude_remove() {
	if [ ! -f "$CLAUDE_JSON" ] || ! grep -q '"cosift"' "$CLAUDE_JSON"; then
		say "claude: no cosift entry found, nothing to remove."
		return 0
	fi
	# Losing Claude Code must not make --uninstall impossible; only a real leftover
	# entry is worth blocking on, and then only with instructions.
	if ! have_cmd claude; then
		err "claude is not on PATH, but $CLAUDE_JSON still has a cosift entry."
		err "remove it once Claude Code is available:"
		err "  claude mcp remove cosift --scope user"
		err "or edit $CLAUDE_JSON by hand: delete the \"cosift\" key (and the object"
		err "after it) from the top-level \"mcpServers\" object."
		return 1
	fi
	if ! claude_json_ok; then
		claude_refuse_malformed
		return 1
	fi
	if ! ensure_backup "$CLAUDE_JSON"; then return 1; fi
	claude mcp remove cosift --scope user >"$TMPD/claude.rm" 2>&1
	if [ -n "$(claude_user_entry)" ]; then
		err "cosift is still present in the Claude Code user config after removal:"
		redact <"$TMPD/claude.rm" >&2
		return 1
	fi
	claude_project_dirs >"$TMPD/claude.projdirs" 2>/dev/null || :
	while IFS= read -r _pd; do
		[ -n "$_pd" ] || continue
		if [ -d "$_pd" ]; then
			(cd "$_pd" && claude mcp remove cosift --scope local) >/dev/null 2>&1 || :
		fi
	done <"$TMPD/claude.projdirs"
	claude_project_dirs >"$TMPD/claude.projleft" 2>/dev/null || :
	if [ -s "$TMPD/claude.projleft" ]; then
		err "a cosift entry still holds a live credential in these Claude Code project"
		err "scopes, and we could not remove it:"
		while IFS= read -r _pd; do
			[ -n "$_pd" ] && err "  $_pd"
		done <"$TMPD/claude.projleft"
		err "remove each one with:  cd <dir> && claude mcp remove cosift"
		return 1
	fi
	if [ "$JSON_PARSER" = "awk" ] && grep -q '"cosift"' "$CLAUDE_JSON"; then
		warn "$CLAUDE_JSON still mentions cosift. Without python3 or node we cannot tell"
		warn "whether that is a project-scoped entry holding a live credential. Check with:"
		warn "  claude mcp list"
		return 1
	fi
	return 0
}

claude_manual_help() {
	say "  claude mcp add --transport http --scope user cosift '$COSIFT_MCP_URL' \\"
	say "    --header 'Authorization: Bearer <your ck_ token>'"
}

# --------------------------------------------------------- harness: codex cli

codex_detect() {
	if have_cmd codex; then return 0; fi
	[ -f "$CODEX_CONFIG" ]
}

codex_block() {
	if [ -f "$CODEX_CONFIG" ]; then
		awk '
			/^# >>> cosift/ { ins = 1; next }
			/^# <<< cosift/ { ins = 0; next }
			ins { print }
		' "$CODEX_CONFIG" 2>/dev/null
	fi
}

codex_recover_token() {
	codex_block | grep -Eo "$TOKEN_RE" 2>/dev/null
}

codex_has_marker_block() {
	[ -f "$CODEX_CONFIG" ] && grep -q '^# >>> cosift' "$CODEX_CONFIG"
}

codex_is_configured() {
	codex_has_marker_block
}

# Our entry, in our block: a cosift table outside our markers belongs to someone else.
codex_up_to_date() {
	codex_has_marker_block || return 1
	_b=$(codex_block)
	case "$_b" in
	*"$COSIFT_MCP_URL"*) ;;
	*) return 1 ;;
	esac
	case "$_b" in
	*"Bearer $1"*) return 0 ;;
	esac
	return 1
}

# Non-zero when an [mcp_servers.cosift] table exists outside our markers: a second
# table of the same name is a TOML parse error, so we refuse rather than corrupt.
# [mcp_servers."cosift"] and [ mcp_servers . cosift ] are that same table in TOML.
codex_foreign_table() {
	if [ ! -f "$CODEX_CONFIG" ]; then return 1; fi
	awk '
		/^# >>> cosift/ { ins = 1; next }
		/^# <<< cosift/ { ins = 0; next }
		{
			h = $0
			gsub("[\"\047 \t]", "", h)
			if (h ~ /^\[/) {
				if (!ins && h ~ /^\[mcp_servers\.cosift[].]/) bad = 1
				tbl = h
				next
			}
			if (!ins && tbl == "[mcp_servers]" && h ~ /^cosift=/) bad = 1
			if (!ins && tbl == "" && h ~ /^mcp_servers\.cosift=/) bad = 1
		}
		END { exit(bad ? 0 : 1) }
	' "$CODEX_CONFIG"
}

# A cosift server declared twice makes codex refuse to start at all, so this is checked
# on the file we wrote even when the codex binary is not around to check it for us.
# Quoting and padding are normalised away: they name the same TOML table.
codex_duplicate_table() {
	awk '
		/^[ \t]*\[/ {
			h = $0
			sub(/[ \t]*$/, "", h)
			gsub("[\"\047 \t]", "", h)
			tbl = h
			if (h ~ /^\[mcp_servers\.cosift[].]/ && seen[h]++) dup = 1
			next
		}
		{
			h = $0
			gsub("[\"\047 \t]", "", h)
			if (tbl == "[mcp_servers]" && h ~ /^cosift=/) dup = 1
			if (tbl == "" && h ~ /^mcp_servers\.cosift=/) dup = 1
		}
		END { exit(dup ? 0 : 1) }
	' "$1"
}

# A table header that never closes means the file is already unparseable; appending to
# it would bury the real error under ours. A line that starts with "[" inside a
# multi-line string or a multi-line array is not a header, so it is not our business.
codex_config_sane() {
	if [ ! -f "$CODEX_CONFIG" ]; then return 0; fi
	awk '
		function odd(s, d,   n, i) {
			n = 0
			i = index(s, d)
			while (i) { n++; s = substr(s, i + length(d)); i = index(s, d) }
			return n % 2
		}
		{
			if (inml) { if (odd($0, "\"\"\"")) inml = 0; next }
			if (odd($0, "\"\"\"")) { inml = 1; next }
			if ($0 ~ /^[ \t]*\[/ && $0 !~ /]/) bad = 1
		}
		END { exit(bad ? 1 : 0) }
	' "$CODEX_CONFIG"
}

# The line number of an opening marker with no closing marker after it.
codex_unterminated_marker() {
	if [ ! -f "$CODEX_CONFIG" ]; then return 0; fi
	awk '
		/^# >>> cosift/ { o = NR; next }
		/^# <<< cosift/ { o = 0; next }
		END { if (o) print o }
	' "$CODEX_CONFIG"
}

codex_refuse_unterminated() {
	err "$CODEX_CONFIG opens our block at line $1 and never closes it:"
	err "  line $1: $CODEX_MARK_OPEN"
	err "  expected somewhere after it: $CODEX_MARK_CLOSE"
	err "without the closing marker we cannot tell where our block ends, and removing"
	err "it would delete everything from line $1 to the end of the file. Inspect lines"
	err "$1-$2, put the closing marker back after the last cosift line, then re-run."
}

codex_server_names() {
	if [ -f "$1" ]; then
		grep -Eo '^[ 	]*\[mcp_servers\.[A-Za-z0-9_-]+\]' "$1" 2>/dev/null |
			sed -e 's/.*\.\([A-Za-z0-9_-]*\)\]/\1/'
	fi
}

codex_strip_block() {
	awk '
		/^[ \t]*$/ { if (!skip) pending = pending $0 "\n"; next }
		/^# >>> cosift/ { skip = 1; pending = ""; next }
		/^# <<< cosift/ { if (skip) { skip = 0; next } }
		{ if (!skip) { printf "%s", pending; pending = ""; print } }
		# An unclosed block would otherwise mean "delete to EOF"; callers refuse instead.
		END { if (skip) exit 1; printf "%s", pending }
	' "$1"
}

codex_write_block() {
	printf '%s\n' "$CODEX_MARK_OPEN" >>"$1"
	printf '[mcp_servers.cosift]\n' >>"$1"
	printf 'url = "%s"\n' "$COSIFT_MCP_URL" >>"$1"
	printf '[mcp_servers.cosift.http_headers]\n' >>"$1"
	printf 'Authorization = "Bearer %s"\n' "$2" >>"$1"
	if [ -n "$COSIFT_EXTRA_HEADER" ]; then
		_hn=${COSIFT_EXTRA_HEADER%%:*}
		_hv=${COSIFT_EXTRA_HEADER#*:}
		_hv=${_hv# }
		printf '%s = "%s"\n' "$_hn" "$_hv" >>"$1"
	fi
	printf '%s\n' "$CODEX_MARK_CLOSE" >>"$1"
}

codex_cli_ok() {
	have_cmd codex && codex mcp list >/dev/null 2>&1
}

codex_add() {
	_tok=$1
	if ! codex_config_sane; then
		err "$CODEX_CONFIG has an unterminated table header, so it is not valid TOML."
		err "we will not append to a file codex already cannot read. Fix the header"
		err "(look for a line starting with '[' that never closes) and re-run."
		return 1
	fi
	if codex_foreign_table; then
		err "$CODEX_CONFIG already declares [mcp_servers.cosift] outside our markers."
		err "adding a second table of that name would make the file unparseable."
		err "remove or rename the existing table, then re-run."
		return 1
	fi
	_open=$(codex_unterminated_marker)
	if [ -n "$_open" ]; then
		codex_refuse_unterminated "$_open" "$(wc -l <"$CODEX_CONFIG" | tr -d ' ')"
		return 1
	fi
	if ! ensure_backup "$CODEX_CONFIG"; then return 1; fi
	_bak=$BACKUP_PATH
	_cli_before=1
	if codex_cli_ok; then _cli_before=0; fi
	codex_server_names "$CODEX_CONFIG" >"$TMPD/codex.before"
	_new="$TMPD/codex.toml"
	: >"$_new"
	chmod 600 "$_new" 2>/dev/null
	if [ -f "$CODEX_CONFIG" ]; then
		if ! codex_strip_block "$CODEX_CONFIG" >"$_new"; then
			err "could not rewrite $CODEX_CONFIG"
			return 1
		fi
		if [ -s "$_new" ]; then printf '\n' >>"$_new"; fi
	fi
	codex_write_block "$_new" "$_tok"
	if [ ! -d "$CODEX_HOME_DIR" ]; then
		if ! mkdir -p "$CODEX_HOME_DIR"; then
			err "could not create $CODEX_HOME_DIR"
			return 1
		fi
	fi
	if [ -f "$CODEX_CONFIG" ]; then
		if ! cp "$_new" "$CODEX_CONFIG"; then
			err "could not write $CODEX_CONFIG"
			return 1
		fi
	else
		if ! cp "$_new" "$CODEX_CONFIG"; then
			err "could not write $CODEX_CONFIG"
			return 1
		fi
		chmod 600 "$CODEX_CONFIG" 2>/dev/null
	fi
	if ! grep -q '^\[mcp_servers\.cosift\]' "$CODEX_CONFIG" ||
		! codex_has_marker_block; then
		err "the cosift block is not present in $CODEX_CONFIG after writing it."
		restore_backup "$CODEX_CONFIG" "$_bak"
		return 1
	fi
	if codex_duplicate_table "$CODEX_CONFIG"; then
		err "$CODEX_CONFIG declares [mcp_servers.cosift] twice after our change, which"
		err "codex reads as a duplicate key and refuses to start on; restoring the backup."
		err "remove or rename the cosift table you already had, then re-run."
		restore_backup "$CODEX_CONFIG" "$_bak"
		return 1
	fi
	codex_server_names "$CODEX_CONFIG" >"$TMPD/codex.after"
	while IFS= read -r _name; do
		if [ -z "$_name" ] || [ "$_name" = "cosift" ]; then continue; fi
		if ! grep -q "^$_name\$" "$TMPD/codex.after"; then
			err "the MCP server '$_name' disappeared from $CODEX_CONFIG."
			restore_backup "$CODEX_CONFIG" "$_bak"
			return 1
		fi
	done <"$TMPD/codex.before"
	if [ "$_cli_before" -eq 0 ] && ! codex_cli_ok; then
		err "codex can no longer read its config after our change; restoring the backup."
		restore_backup "$CODEX_CONFIG" "$_bak"
		return 1
	fi
	harden_mode "$CODEX_CONFIG"
	return 0
}

codex_remove() {
	if [ ! -f "$CODEX_CONFIG" ]; then
		say "codex: no config at $CODEX_CONFIG, nothing to remove."
		return 0
	fi
	if ! codex_has_marker_block; then
		if codex_foreign_table; then
			err "$CODEX_CONFIG has an [mcp_servers.cosift] table we did not write."
			err "leaving it alone - remove it by hand if you want it gone."
			return 1
		fi
		say "codex: no cosift block found, nothing to remove."
		return 0
	fi
	_open=$(codex_unterminated_marker)
	if [ -n "$_open" ]; then
		codex_refuse_unterminated "$_open" "$(wc -l <"$CODEX_CONFIG" | tr -d ' ')"
		return 1
	fi
	if ! ensure_backup "$CODEX_CONFIG"; then return 1; fi
	_bak=$BACKUP_PATH
	_new="$TMPD/codex.rm.toml"
	if ! codex_strip_block "$CODEX_CONFIG" >"$_new"; then
		err "could not rewrite $CODEX_CONFIG"
		return 1
	fi
	if ! cp "$_new" "$CODEX_CONFIG"; then
		err "could not write $CODEX_CONFIG"
		return 1
	fi
	if codex_has_marker_block || grep -q '^\[mcp_servers\.cosift\]' "$CODEX_CONFIG"; then
		err "the cosift block survived removal; restoring the backup."
		restore_backup "$CODEX_CONFIG" "$_bak"
		return 1
	fi
	if have_cmd codex && ! codex mcp list >/dev/null 2>&1; then
		err "codex cannot read its config after removal; restoring the backup."
		restore_backup "$CODEX_CONFIG" "$_bak"
		return 1
	fi
	return 0
}

# ----------------------------------------------------------- harness: opencode

opencode_config_path() {
	if [ -f "$OPENCODE_DIR/opencode.json" ]; then
		printf '%s\n' "$OPENCODE_DIR/opencode.json"
	elif [ -f "$OPENCODE_DIR/opencode.jsonc" ]; then
		printf '%s\n' "$OPENCODE_DIR/opencode.jsonc"
	else
		printf '%s\n' "$OPENCODE_DIR/opencode.json"
	fi
}

opencode_detect() {
	if have_cmd opencode; then return 0; fi
	[ -f "$OPENCODE_DIR/opencode.json" ] || [ -f "$OPENCODE_DIR/opencode.jsonc" ]
}

opencode_recover_token() {
	for _f in "$OPENCODE_DIR/opencode.json" "$OPENCODE_DIR/opencode.jsonc"; do
		if [ -f "$_f" ]; then
			grep -Eo "$TOKEN_RE" "$_f" 2>/dev/null
		fi
	done
}

opencode_is_configured() {
	_cfg=$(opencode_config_path)
	[ -f "$_cfg" ] && opencode_jsonc list "$_cfg" 2>/dev/null | grep -q '^cosift$'
}

# Our entry, inside the top-level "mcp" object of the config we manage.
opencode_up_to_date() {
	_cfg=$(opencode_config_path)
	[ -f "$_cfg" ] || return 1
	_e=$(opencode_jsonc entry "$_cfg" 2>/dev/null) || return 1
	if [ -z "$_e" ]; then return 1; fi
	case "$_e" in
	*"$COSIFT_MCP_URL"*) ;;
	*) return 1 ;;
	esac
	case "$_e" in
	*"Bearer $1"*) return 0 ;;
	esac
	return 1
}

# opencode configs are JSONC: comments and trailing commas are legal, so jq and
# python json both reject real files. This hand-rolled scanner is string-aware and
# comment-aware - a brace inside "a } string" or a // comment must not move the
# depth, or we would cut the file at the wrong byte.
# modes: list (print the keys of the "mcp" object) | entry (print the raw text of
# mcp.cosift) | remove (emit the file with the cosift member deleted).
# Exit 2 = not found, 3 = shape we refuse to touch.
opencode_jsonc() {
	awk -v MODE="$1" '
	function skipws(p,   c, d) {
		while (p <= N) {
			c = substr(B, p, 1)
			if (c == " " || c == "\t" || c == "\r" || c == "\n") { p++; continue }
			if (c == "/") {
				d = substr(B, p + 1, 1)
				if (d == "/") {
					while (p <= N && substr(B, p, 1) != "\n") p++
					continue
				}
				if (d == "*") {
					p += 2
					while (p <= N && !(substr(B, p, 1) == "*" && substr(B, p + 1, 1) == "/")) p++
					p += 2
					continue
				}
			}
			break
		}
		return p
	}
	function endstr(p,   c) {
		p++
		while (p <= N) {
			c = substr(B, p, 1)
			if (c == "\\") { p += 2; continue }
			if (c == "\"") return p + 1
			p++
		}
		return 0
	}
	function endval(p,   c, d, e) {
		c = substr(B, p, 1)
		if (c == "\"") return endstr(p)
		if (c == "{" || c == "[") {
			d = 0
			while (p <= N) {
				c = substr(B, p, 1)
				if (c == "\"") {
					p = endstr(p)
					if (p == 0) return 0
					continue
				}
				if (c == "/") {
					e = substr(B, p + 1, 1)
					if (e == "/" || e == "*") { p = skipws(p); continue }
				}
				if (c == "{" || c == "[") { d++; p++; continue }
				if (c == "}" || c == "]") {
					d--
					p++
					if (d == 0) return p
					continue
				}
				p++
			}
			return 0
		}
		while (p <= N) {
			c = substr(B, p, 1)
			if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\r" || c == "\n") break
			p++
		}
		return p
	}
	function members(objp, want,   p, c, ks, ke, k, vs, ve, prevc) {
		M_ks = 0; M_vs = 0; M_ve = 0; M_prevc = 0; M_nextc = 0
		prevc = 0
		p = skipws(objp + 1)
		while (p <= N) {
			c = substr(B, p, 1)
			if (c == "}") return 0
			if (c != "\"") return -1
			ks = p
			ke = endstr(p)
			if (ke == 0) return -1
			k = substr(B, ks + 1, ke - ks - 2)
			p = skipws(ke)
			if (substr(B, p, 1) != ":") return -1
			vs = skipws(p + 1)
			ve = endval(vs)
			if (ve == 0) return -1
			if (PRINTKEYS) print k
			p = skipws(ve)
			c = substr(B, p, 1)
			if (want != "" && k == want) {
				M_ks = ks; M_vs = vs; M_ve = ve; M_prevc = prevc
				M_nextc = 0
				if (c == ",") M_nextc = p
				return 1
			}
			if (c == ",") { prevc = p; p = skipws(p + 1); continue }
			if (c == "}") return 0
			return -1
		}
		return -1
	}
	{ B = B $0 "\n" }
	END {
		N = length(B)
		p = skipws(1)
		if (substr(B, p, 1) != "{") exit 3
		r = members(p, "mcp")
		if (r < 0) exit 3
		if (r == 0) { if (MODE == "list") exit 0; exit 2 }
		q = M_vs
		if (substr(B, q, 1) != "{") exit 3
		if (MODE == "list") {
			PRINTKEYS = 1
			if (members(q, "") < 0) exit 3
			exit 0
		}
		r = members(q, "cosift")
		if (r < 0) exit 3
		if (r == 0) exit 2
		if (MODE == "entry") { printf "%s", substr(B, M_vs, M_ve - M_vs); exit 0 }
		ds = M_ks
		de = M_ve
		if (M_nextc > 0) de = M_nextc + 1
		else if (M_prevc > 0) ds = M_prevc
		while (ds > 1 && (substr(B, ds - 1, 1) == " " || substr(B, ds - 1, 1) == "\t")) ds--
		if (ds > 1 && substr(B, ds - 1, 1) == "\n" && substr(B, de, 1) == "\n") de++
		printf "%s%s", substr(B, 1, ds - 1), substr(B, de)
		exit 0
	}' "$2"
}

opencode_server_names() {
	if [ -f "$1" ]; then
		opencode_jsonc list "$1" 2>/dev/null
	fi
}

opencode_add() {
	_tok=$1
	_cfg=$(opencode_config_path)
	if ! have_cmd opencode; then
		err "opencode is not on PATH. Its config is JSONC (comments, trailing commas),"
		err "so we will not hand-edit it to add an entry. Install opencode and re-run,"
		err "or add the server yourself:"
		opencode_manual_help
		return 1
	fi
	# Backup first: `opencode mcp list` rewrites the config (it injects "$schema").
	if [ -f "$_cfg" ]; then
		if ! ensure_backup "$_cfg"; then return 1; fi
		_bak=$BACKUP_PATH
	else
		_bak=""
		if ! mkdir -p "$OPENCODE_DIR"; then
			err "could not create $OPENCODE_DIR"
			return 1
		fi
	fi
	opencode_server_names "$_cfg" >"$TMPD/opencode.before"
	# `opencode mcp add --header` also exposes the token in argv; accepted here for
	# the same reason as Claude Code. Note KEY=VALUE, not the colon form.
	if [ -n "$COSIFT_EXTRA_HEADER" ]; then
		_hn=${COSIFT_EXTRA_HEADER%%:*}
		_hv=${COSIFT_EXTRA_HEADER#*:}
		_hv=${_hv# }
		opencode mcp add cosift --url "$COSIFT_MCP_URL" \
			--header "Authorization=Bearer $_tok" \
			--header "$_hn=$_hv" >"$TMPD/opencode.add" 2>&1
		_rc=$?
	else
		opencode mcp add cosift --url "$COSIFT_MCP_URL" \
			--header "Authorization=Bearer $_tok" >"$TMPD/opencode.add" 2>&1
		_rc=$?
	fi
	if [ "$_rc" -ne 0 ]; then
		err "opencode mcp add failed:"
		redact <"$TMPD/opencode.add" >&2
		if [ -n "$_bak" ]; then restore_backup "$_cfg" "$_bak"; fi
		return 1
	fi
	_cfg=$(opencode_config_path)
	if [ ! -f "$_cfg" ] || ! grep -q '"cosift"' "$_cfg"; then
		err "opencode reported success but cosift is not in $_cfg."
		if [ -n "$_bak" ]; then restore_backup "$_cfg" "$_bak"; fi
		return 1
	fi
	if ! opencode mcp list >"$TMPD/opencode.after" 2>&1; then
		err "opencode cannot read its config after our change:"
		redact <"$TMPD/opencode.after" >&2
		if [ -n "$_bak" ]; then restore_backup "$_cfg" "$_bak"; fi
		return 1
	fi
	redact <"$TMPD/opencode.after" >"$TMPD/opencode.after.r"
	if ! grep -q 'cosift' "$TMPD/opencode.after.r"; then
		err "opencode does not list cosift after adding it."
		if [ -n "$_bak" ]; then restore_backup "$_cfg" "$_bak"; fi
		return 1
	fi
	# Compared against the parsed config, not the CLI's decorated output, which has no
	# stable name column to read.
	opencode_server_names "$_cfg" >"$TMPD/opencode.names.after"
	while IFS= read -r _name; do
		if [ -z "$_name" ] || [ "$_name" = "cosift" ]; then continue; fi
		if ! grep -Fqx -e "$_name" "$TMPD/opencode.names.after"; then
			err "the MCP server '$_name' disappeared from $_cfg."
			if [ -n "$_bak" ]; then restore_backup "$_cfg" "$_bak"; fi
			return 1
		fi
	done <"$TMPD/opencode.before"
	harden_mode "$_cfg"
	return 0
}

opencode_remove() {
	_cfg=$(opencode_config_path)
	if [ ! -f "$_cfg" ]; then
		say "opencode: no config at $_cfg, nothing to remove."
		return 0
	fi
	if ! opencode_jsonc list "$_cfg" 2>/dev/null | grep -q '^cosift$'; then
		if ! grep -q '"cosift"' "$_cfg"; then
			say "opencode: no cosift entry found, nothing to remove."
			return 0
		fi
	fi
	if ! ensure_backup "$_cfg"; then return 1; fi
	_bak=$BACKUP_PATH
	_new="$TMPD/opencode.new"
	opencode_jsonc remove "$_cfg" >"$_new" 2>"$TMPD/opencode.awkerr"
	_rc=$?
	if [ "$_rc" -eq 2 ]; then
		say "opencode: no cosift entry inside the mcp object, nothing to remove."
		return 0
	fi
	if [ "$_rc" -ne 0 ]; then
		err "$_cfg is not in a shape we can edit safely; refusing to touch it."
		opencode_manual_removal_help "$_cfg"
		return 1
	fi
	if ! cp "$_new" "$_cfg"; then
		err "could not write $_cfg"
		restore_backup "$_cfg" "$_bak"
		return 1
	fi
	if opencode_jsonc list "$_cfg" 2>/dev/null | grep -q '^cosift$'; then
		err "cosift is still in $_cfg after removal; restoring the backup."
		restore_backup "$_cfg" "$_bak"
		opencode_manual_removal_help "$_cfg"
		return 1
	fi
	if have_cmd opencode; then
		if ! opencode mcp list >"$TMPD/opencode.vfy" 2>&1; then
			err "opencode cannot read $_cfg after removal; restoring the backup."
			redact <"$TMPD/opencode.vfy" >&2
			restore_backup "$_cfg" "$_bak"
			opencode_manual_removal_help "$_cfg"
			return 1
		fi
		if redact <"$TMPD/opencode.vfy" | grep -q 'cosift'; then
			err "opencode still lists cosift after removal; restoring the backup."
			restore_backup "$_cfg" "$_bak"
			opencode_manual_removal_help "$_cfg"
			return 1
		fi
	fi
	return 0
}

opencode_manual_help() {
	say "  opencode mcp add cosift --url '$COSIFT_MCP_URL' \\"
	say "    --header 'Authorization=Bearer <your ck_ token>'"
}

opencode_manual_removal_help() {
	say ""
	say "Manual removal instructions - do this by hand:"
	say "  1. open $1"
	say "  2. inside the top-level \"mcp\" object, delete the \"cosift\" key and the"
	say "     whole object that follows it, plus the comma that is now dangling"
	say "  3. save, then run: opencode mcp list"
	say "  Your original file is at: ${BACKUP_PATH:-<no backup>}"
	say ""
}

# ---------------------------------------------------------------- harness glue

harness_detect() {
	case "$1" in
	claude) claude_detect ;;
	codex) codex_detect ;;
	opencode) opencode_detect ;;
	*) return 1 ;;
	esac
}

harness_is_configured() {
	case "$1" in
	claude) claude_is_configured ;;
	codex) codex_is_configured ;;
	opencode) opencode_is_configured ;;
	*) return 1 ;;
	esac
}

# Re-running must not rewrite a config that already holds this exact credential and
# URL: a second backup would capture the already-configured state, and the newest
# backup would no longer be the pre-Cosift one a user restores from.
# Each harness answers for the entry in the scope we write, not for any occurrence of
# the token anywhere in the file, and compares the token without an argv.
harness_up_to_date() {
	case "$1" in
	claude) claude_up_to_date "$2" ;;
	codex) codex_up_to_date "$2" ;;
	opencode) opencode_up_to_date "$2" ;;
	*) return 1 ;;
	esac
}

harness_add() {
	case "$1" in
	claude) claude_add "$2" ;;
	codex) codex_add "$2" ;;
	opencode) opencode_add "$2" ;;
	*) return 1 ;;
	esac
}

harness_remove() {
	case "$1" in
	claude) claude_remove ;;
	codex) codex_remove ;;
	opencode) opencode_remove ;;
	*) return 1 ;;
	esac
}

harness_config_path() {
	case "$1" in
	claude) printf '%s\n' "$CLAUDE_JSON" ;;
	codex) printf '%s\n' "$CODEX_CONFIG" ;;
	opencode) opencode_config_path ;;
	esac
}

harness_label() {
	case "$1" in
	claude) printf '%s\n' "Claude Code" ;;
	codex) printf '%s\n' "OpenAI Codex CLI" ;;
	opencode) printf '%s\n' "opencode" ;;
	esac
}

detect_all() {
	DETECTED=""
	for _h in claude codex opencode; do
		if harness_detect "$_h"; then
			DETECTED=$(list_add "$DETECTED" "$_h")
		fi
	done
}

# ------------------------------------------------------------ token recovery

recover_candidates() {
	{
		claude_recover_token
		codex_recover_token
		opencode_recover_token
	} 2>/dev/null | awk 'NF > 0 && !seen[$0]++'
}

# The endpoint is the arbiter, not the regex, so a loose extraction stays safe.
try_recover_token() {
	_cands="$TMPD/candidates"
	recover_candidates >"$_cands"
	if [ ! -s "$_cands" ]; then return 1; fi
	_n=0
	while IFS= read -r _cand; do
		if [ -z "$_cand" ]; then continue; fi
		_n=$((_n + 1))
		_st=$(mcp_initialize "$_cand")
		if [ "$_st" = "200" ]; then
			TOKEN=$_cand
			say "Reusing the Cosift credential already on this machine: $(token_display "$TOKEN")"
			return 0
		fi
		if [ "$_st" = "403" ]; then
			mcp_explain 403
			exit "$EX_AUTH"
		fi
	done <"$_cands"
	if [ "$_n" -gt 0 ]; then
		say "Found $_n existing ck_ credential(s), none of which the server still accepts."
	fi
	return 1
}

# ----------------------------------------------------------------- state file

write_state() {
	if ! mkdir -p "$STATE_DIR"; then
		err "could not create $STATE_DIR"
		return 1
	fi
	chmod 700 "$STATE_DIR" 2>/dev/null
	_arr=""
	for _h in $CONFIGURED; do
		if [ -z "$_arr" ]; then
			_arr="\"$_h\""
		else
			_arr="$_arr,\"$_h\""
		fi
	done
	_tmp="$TMPD/state.json"
	printf '{"version":"%s","account_uid":"%s","harnesses_configured":[%s],"onboarded":false,"installed_at":"%s"}\n' \
		"$VERSION" "$ACCOUNT_UID" "$_arr" "$(now_rfc3339)" >"$_tmp"
	if ! cp "$_tmp" "$STATE_FILE"; then
		err "could not write $STATE_FILE"
		return 1
	fi
	chmod 600 "$STATE_FILE" 2>/dev/null
	return 0
}

state_harnesses() {
	if [ ! -f "$STATE_FILE" ]; then return 1; fi
	tr -d ' \n\t' <"$STATE_FILE" |
		sed -n 's/.*"harnesses_configured":\[\([^]]*\)\].*/\1/p' |
		tr -d '"' | tr ',' ' '
}

# ---------------------------------------------------------------------- usage

usage() {
	cat <<EOF
cosift-install $VERSION - register the Cosift MCP server with your AI harnesses.

USAGE
  install.sh [OPTIONS]

OPTIONS
  --dry-run          print planned changes; write nothing to disk
  --uninstall        remove the cosift entry from every configured harness
  --harness=LIST     comma-separated subset of: claude,codex,opencode
  --yes              accept all detected harnesses without prompting
  --help             show this help and exit
  --version          print the version and exit

ENVIRONMENT
  COSIFT_AUTH_BASE      override the auth base URL
                        (default: https://cosift-auth.pilotprotocol.network)
  COSIFT_MCP_URL        override the MCP URL
                        (default: https://cosift-mcp.pilotprotocol.network/v1/mcp)
  COSIFT_EXTRA_HEADER   one extra header in "Name: value" form, sent on every
                        request and written into each harness config alongside
                        Authorization

EXIT CODES
  0  success
  2  usage error
  3  preflight failure (curl missing, HOME unwritable, no harness found)
  4  authentication failure
  5  harness write failure
  6  interaction needed but no usable /dev/tty

Configs written by this installer contain a live credential.
Undo with: install.sh --uninstall
EOF
}

# ------------------------------------------------------------------- the flow

# The value lands in a curl -K config line and in a TOML basic string, where a newline
# is a new curl directive (token exfiltration) and a quote or backslash silently
# rewrites the header. Neither file format has an escape we can rely on, so the only
# safe answer is to refuse anything that is not a plain header.
check_extra_header() {
	case "$COSIFT_EXTRA_HEADER" in
	*"$NL"* | *"$CR"*)
		die "$EX_USAGE" "COSIFT_EXTRA_HEADER must be a single line: it is written into a curl config file, where a newline starts a new directive."
		;;
	*'"'* | *\\*)
		die "$EX_USAGE" "COSIFT_EXTRA_HEADER must not contain a double quote or a backslash: both are escape characters in the files we write it into."
		;;
	*:*) ;;
	*)
		die "$EX_USAGE" "COSIFT_EXTRA_HEADER must be in \"Name: value\" form."
		;;
	esac
	_hn=${COSIFT_EXTRA_HEADER%%:*}
	case "$_hn" in
	"" | *[!A-Za-z0-9-]*)
		die "$EX_USAGE" "COSIFT_EXTRA_HEADER has an invalid header name '$_hn': expected letters, digits and '-' before the colon."
		;;
	esac
}

preflight() {
	if [ "$OPT_UNINSTALL" -eq 0 ] && ! have_cmd curl; then
		die "$EX_PREFLIGHT" "curl is required but not installed."
	fi
	if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
		die "$EX_PREFLIGHT" "HOME is not set to a directory; cannot locate any config."
	fi
	if [ "$OPT_DRY_RUN" -eq 0 ] && [ ! -w "$HOME" ]; then
		die "$EX_PREFLIGHT" "$HOME is not writable."
	fi
	if [ -n "$COSIFT_EXTRA_HEADER" ]; then
		check_extra_header
	fi
}

select_harnesses() {
	if [ -n "$OPT_HARNESS" ]; then
		SELECTED=""
		for _h in $(printf '%s\n' "$OPT_HARNESS" | tr ',' ' '); do
			if in_list "$_h" "$SELECTED"; then continue; fi
			SELECTED=$(list_add "$SELECTED" "$_h")
			if ! in_list "$_h" "$DETECTED"; then
				warn "$_h was requested but not detected on this machine; trying anyway."
			fi
		done
		return 0
	fi
	if [ "$OPT_YES" -eq 1 ]; then
		SELECTED=$DETECTED
		return 0
	fi
	require_tty
	say ""
	say "Detected harnesses:"
	_i=0
	for _h in $DETECTED; do
		_i=$((_i + 1))
		say "  $_i) $_h  ($(harness_label "$_h"))"
	done
	say ""
	if ! tty_ask "Configure which? [Enter = all, or e.g. 1,2 or claude,codex]: "; then
		die "$EX_NOTTY" "could not read a selection."
	fi
	_ans=$TTY_REPLY
	case "$_ans" in
	"" | a | A | all | ALL)
		SELECTED=$DETECTED
		return 0
		;;
	esac
	SELECTED=""
	for _tok in $(printf '%s\n' "$_ans" | tr ',' ' '); do
		case "$_tok" in
		[0-9]*)
			_i=0
			_hit=""
			for _h in $DETECTED; do
				_i=$((_i + 1))
				if [ "$_i" = "$_tok" ]; then _hit=$_h; fi
			done
			if [ -z "$_hit" ]; then
				die "$EX_USAGE" "no harness numbered $_tok in the list above."
			fi
			SELECTED=$(list_add "$SELECTED" "$_hit")
			;;
		*)
			if ! in_list "$_tok" "$DETECTED"; then
				die "$EX_USAGE" "'$_tok' is not one of the detected harnesses."
			fi
			SELECTED=$(list_add "$SELECTED" "$_tok")
			;;
		esac
	done
	if [ -z "$SELECTED" ]; then
		die "$EX_USAGE" "nothing selected."
	fi
	return 0
}

obtain_token() {
	step "Looking for a Cosift credential you already have"
	if try_recover_token; then return 0; fi
	if ! email_flow; then
		exit "$EX_AUTH"
	fi
	return 0
}

configure_harnesses() {
	for _h in $SELECTED; do
		step "Configuring $(harness_label "$_h")"
		BACKUP_PATH=""
		if harness_up_to_date "$_h" "$TOKEN"; then
			CONFIGURED=$(list_add "$CONFIGURED" "$_h")
			# "Untouched" covers the contents; an exposed mode on a file already
			# holding the token is still ours to fix.
			harden_mode "$(harness_config_path "$_h")" || :
			say "    already up to date - left untouched"
			continue
		fi
		if ! harness_add "$_h" "$TOKEN"; then
			err "failed to configure $_h; no further harnesses will be touched."
			if [ -n "$CONFIGURED" ]; then
				err "already configured: $CONFIGURED (remove with --uninstall)"
			fi
			exit "$EX_HARNESS"
		fi
		CONFIGURED=$(list_add "$CONFIGURED" "$_h")
		_cfg=$(harness_config_path "$_h")
		say "    wrote $_cfg"
		if [ -n "$BACKUP_PATH" ]; then
			say "    backup $BACKUP_PATH"
		fi
	done
}

final_verify() {
	step "Verifying the credential against $COSIFT_MCP_URL"
	_st=$(mcp_initialize "$TOKEN")
	case "$_st" in
	200)
		say "    ok"
		return 0
		;;
	401 | 403)
		mcp_explain "$_st"
		exit "$EX_AUTH"
		;;
	421)
		mcp_explain "$_st"
		exit "$EX_HARNESS"
		;;
	*)
		mcp_explain "$_st"
		warn "the harness configs were written and look correct; this is a transient"
		warn "server or network problem, so nothing was rolled back."
		return 1
		;;
	esac
}

summary() {
	say ""
	say "Done. Cosift is registered with: $CONFIGURED"
	for _h in $CONFIGURED; do
		say "  - $(harness_label "$_h"): $(harness_config_path "$_h")"
	done
	say ""
	say "Those files now hold a live credential ($(token_display "$TOKEN")). Anyone who"
	say "can read them can use your Cosift account, so keep them off shared machines"
	say "and out of dotfile repositories."
	say ""
	say "State file: $STATE_FILE (mode 0600)"
	say "Backups of every file we touched are kept next to the original, named"
	say "<path>.cosift-backup-<UTC timestamp>."
	if [ -n "$TIGHTENED" ]; then
		say ""
		say "These files were group- or world-readable and now hold a credential, so we"
		say "tightened them to 0600:"
		printf '%s\n' "$TIGHTENED" | sed -e 's/^/  - /'
	fi
	say ""
	say "To remove the entries again:  install.sh --uninstall"
	say "That does NOT revoke the credential - revoke it from your Cosift account."
	say ""
	say "Next: the first Cosift tool call from any of these harnesses will offer the"
	say "onboarding interview. Restart the harness if it was running."
}

dry_run() {
	step "Dry run - nothing will be written"
	say ""
	if try_recover_token; then
		say "Token source: an existing credential on this machine would be reused."
		say "              No email verification would be needed."
	else
		say "Token source: no usable credential found, so the installer would ask for"
		say "              your email address and a 6-digit code. (Not doing that now.)"
	fi
	say ""
	for _h in $SELECTED; do
		_cfg=$(harness_config_path "$_h")
		say "$(harness_label "$_h") [$_h]"
		say "  config:  $_cfg"
		if [ -n "$TOKEN" ] && harness_up_to_date "$_h" "$TOKEN"; then
			say "  backup:  none (nothing would be written)"
			say "  status:  already holds this credential; it would be left untouched"
			say ""
			continue
		fi
		if [ -f "$_cfg" ]; then
			say "  backup:  $_cfg.cosift-backup-<UTC timestamp>"
		else
			say "  backup:  none (file does not exist yet, it would be created)"
		fi
		if harness_is_configured "$_h"; then
			say "  status:  a cosift entry is already present; it would be replaced"
		else
			say "  status:  no cosift entry yet; it would be added"
		fi
		case "$_h" in
		claude)
			say "  action:  claude mcp add --transport http --scope user cosift \\"
			say "             '$COSIFT_MCP_URL' --header 'Authorization: Bearer ck_...'"
			;;
		codex)
			say "  action:  append a marker-delimited [mcp_servers.cosift] block:"
			say "             $CODEX_MARK_OPEN"
			say "             [mcp_servers.cosift]"
			say "             url = \"$COSIFT_MCP_URL\""
			say "             [mcp_servers.cosift.http_headers]"
			say "             Authorization = \"Bearer ck_...\""
			say "             $CODEX_MARK_CLOSE"
			if codex_foreign_table; then
				say "  WARNING: an [mcp_servers.cosift] table already exists outside our"
				say "           markers - a real run would refuse (exit 5)."
			fi
			;;
		opencode)
			say "  action:  opencode mcp add cosift --url '$COSIFT_MCP_URL' \\"
			say "             --header 'Authorization=Bearer ck_...'"
			if ! have_cmd opencode; then
				say "  WARNING: opencode is not on PATH - a real run would refuse (exit 5)."
			fi
			;;
		esac
		if [ -n "$COSIFT_EXTRA_HEADER" ]; then
			say "  extra:   ${COSIFT_EXTRA_HEADER%%:*} would also be written into the config"
		fi
		say ""
	done
	say "State that would be written: $STATE_FILE (mode 0600)"
	say "Nothing was written. Re-run without --dry-run to apply."
	exit "$EX_OK"
}

do_install() {
	preflight
	if [ "$OPT_DRY_RUN" -eq 0 ] && [ -z "$OPT_HARNESS" ] && [ "$OPT_YES" -eq 0 ]; then
		require_tty
	fi
	detect_all
	if [ -z "$DETECTED" ] && [ -z "$OPT_HARNESS" ]; then
		err "no supported AI harness found on this machine."
		err "cosift-install can configure Claude Code, the OpenAI Codex CLI and opencode."
		err "install one of them and re-run, or pass --harness=<name> if you know the"
		err "config exists somewhere we did not look."
		exit "$EX_PREFLIGHT"
	fi
	select_harnesses
	if [ "$OPT_DRY_RUN" -eq 1 ]; then
		dry_run
	fi
	obtain_token
	configure_harnesses
	final_verify
	if ! write_state; then
		exit "$EX_HARNESS"
	fi
	summary
	exit "$EX_OK"
}

do_uninstall() {
	preflight
	_targets=$(state_harnesses 2>/dev/null)
	if [ -z "$_targets" ]; then
		if [ -f "$STATE_FILE" ]; then
			say "$STATE_FILE names no harness we can read; looking for our entries directly."
		else
			say "No state file at $STATE_FILE; looking for our entries directly."
		fi
		for _h in claude codex opencode; do
			if harness_is_configured "$_h"; then
				_targets=$(list_add "$_targets" "$_h")
			fi
		done
	fi
	if [ -z "$_targets" ]; then
		say "Nothing to remove: no cosift entry found in any supported harness."
		if [ -f "$STATE_FILE" ]; then
			rm -f "$STATE_FILE"
			say "Removed $STATE_FILE"
		fi
		exit "$EX_OK"
	fi
	_failed=""
	for _h in $_targets; do
		case "$_h" in
		claude | codex | opencode) ;;
		*)
			warn "state names an unknown harness '$_h'; skipping."
			continue
			;;
		esac
		step "Removing cosift from $(harness_label "$_h")"
		BACKUP_PATH=""
		if harness_remove "$_h"; then
			if [ -n "$BACKUP_PATH" ]; then
				say "    backup $BACKUP_PATH"
			fi
		else
			_failed=$(list_add "$_failed" "$_h")
		fi
	done
	if [ -n "$_failed" ]; then
		err "could not remove the cosift entry from: $_failed"
		err "the state file was left in place so you can retry."
		exit "$EX_HARNESS"
	fi
	if [ -f "$STATE_FILE" ]; then
		if ! rm -f "$STATE_FILE"; then
			err "could not remove $STATE_FILE"
			exit "$EX_HARNESS"
		fi
	fi
	say ""
	say "Removed. Backups were left next to each config."
	say "The credential itself is still valid server-side - revoke it from your"
	say "Cosift account if you want it dead."
	exit "$EX_OK"
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--dry-run) OPT_DRY_RUN=1 ;;
		--uninstall) OPT_UNINSTALL=1 ;;
		--yes) OPT_YES=1 ;;
		--harness=*)
			OPT_HARNESS=${1#--harness=}
			if [ -z "$OPT_HARNESS" ]; then
				usage >&2
				exit "$EX_USAGE"
			fi
			for _h in $(printf '%s\n' "$OPT_HARNESS" | tr ',' ' '); do
				case "$_h" in
				claude | codex | opencode) ;;
				*)
					err "unknown harness: $_h (expected claude, codex or opencode)"
					usage >&2
					exit "$EX_USAGE"
					;;
				esac
			done
			;;
		--help)
			usage
			exit "$EX_OK"
			;;
		--version)
			say "cosift-install $VERSION"
			exit "$EX_OK"
			;;
		*)
			err "unknown option: $1"
			usage >&2
			exit "$EX_USAGE"
			;;
		esac
		shift
	done
	if [ "$OPT_DRY_RUN" -eq 1 ] && [ "$OPT_UNINSTALL" -eq 1 ]; then
		err "--dry-run and --uninstall cannot be combined."
		usage >&2
		exit "$EX_USAGE"
	fi
}

main() {
	parse_args "$@"
	init_tmp
	if [ "$OPT_UNINSTALL" -eq 1 ]; then
		do_uninstall
	fi
	do_install
}

main "$@"
