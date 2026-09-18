#!/bin/sh
# Build-time only. Installs the harness CLIs from npm and records, per CLI,
# whether the image got the real thing or a stub. Never fails the build.
set -u

REPORT="${1:-/opt/cosift-test/cli-report.tsv}"
mkdir -p "$(dirname "$REPORT")"
: >"$REPORT"

make_stub() {
    stub_bin="$1"
    stub_pkg="$2"
    rm -f "/usr/local/bin/$stub_bin"
    cat >"/usr/local/bin/$stub_bin" <<EOF
#!/bin/sh
echo "cosift-test: '$stub_bin' is a STUB. The npm package $stub_pkg could not be" >&2
echo "cosift-test: installed when this image was built. Any test that needs the" >&2
echo "cosift-test: real CLI must report SKIP, not PASS." >&2
exit 3
EOF
    chmod 0755 "/usr/local/bin/$stub_bin"
}

try_install() {
    pkg="$1"
    bin="$2"
    log="/tmp/npm-$bin.log"

    if npm install -g --no-fund --no-audit --loglevel=error "$pkg" >"$log" 2>&1 &&
        command -v "$bin" >/dev/null 2>&1 &&
        ver="$(timeout 60 "$bin" --version 2>/dev/null | tr -d '\r' | head -n 1)" &&
        [ -n "${ver:-}" ]; then
        printf 'real\t%s\t%s\t%s\n' "$bin" "$pkg" "$ver" >>"$REPORT"
        return 0
    fi

    reason="$(tail -n 5 "$log" 2>/dev/null | tr '\n\t' '  ' | cut -c1-240)"
    [ -n "$reason" ] || reason="install produced no usable $bin binary"
    make_stub "$bin" "$pkg"
    printf 'stub\t%s\t%s\t%s\n' "$bin" "$pkg" "$reason" >>"$REPORT"
    return 0
}

try_install "@anthropic-ai/claude-code" claude
try_install "@openai/codex" codex
try_install "opencode-ai" opencode

chmod 0644 "$REPORT"
cat "$REPORT"
