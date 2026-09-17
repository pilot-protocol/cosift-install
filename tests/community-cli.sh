#!/bin/sh
# Offline installer handoff tests. Fixtures use only fabricated credentials and
# isolated HOME/PATH values; no real harness configuration or server is read.
set -eu
exec python3 - "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)" <<'PY'
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

INSTALLER = Path(sys.argv.pop(1)) / "install.sh"
TOKEN = "ck_1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
ORIGIN = "https://community.example.invalid"


class CommunityCLIHandoff(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {
            "PATH": str(self.bin) + ":/usr/bin:/bin",
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / "config"),
            "COSIFT_COMMUNITY_URL": ORIGIN,
            "COSIFT_AUTH_BASE": "https://auth.example.invalid",
            "COSIFT_MCP_URL": "https://mcp.example.invalid/v1/mcp",
            "NO_COLOR": "1",
            "CLI_CALL_LOG": str(self.root / "cli-calls.json"),
            "TEST_TOKEN": TOKEN,
        }
        self.session = self.home / "config/cosift/community-session.json"
        config = self.home / ".codex/config.toml"
        config.parent.mkdir()
        config.write_text(
            '# >>> cosift (managed by cosift-install — do not edit)\n'
            '[mcp_servers.cosift]\nurl = "https://mcp.example.invalid/v1/mcp"\n'
            '[mcp_servers.cosift.http_headers]\nAuthorization = "Bearer ' + TOKEN + '"\n'
            '# <<< cosift\n'
        )
        config.chmod(0o600)
        self.executable("codex", "#!/bin/sh\nexit 0\n")
        self.executable("curl", f"#!{sys.executable}\n" + '''
import json, pathlib, sys
args = sys.argv[1:]
out = pathlib.Path(args[args.index("-o") + 1])
out.write_text(json.dumps({"jsonrpc":"2.0", "id":1, "result":{}}))
print("200", end="")
''')
        self.executable("cosift", f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
args = sys.argv[1:]
if args == ["login", "-help"]:
    print("  -session-file string", file=sys.stderr)
    sys.exit(2)
assert args[0] == "login", args
assert os.environ["COSIFT_TOKEN"] == os.environ["TEST_TOKEN"]
assert os.environ.get("COSIFT_SESSION_FILE") == ""
assert os.environ.get("COSIFT_EMAIL") == ""
assert os.environ.get("COSIFT_PASSWORD") == ""
assert os.environ["COSIFT_TOKEN"] not in " ".join(args)
pathlib.Path(os.environ["CLI_CALL_LOG"]).write_text(json.dumps(args))
if os.environ.get("CLI_FAIL"):
    print("rejected " + os.environ["COSIFT_TOKEN"], file=sys.stderr)
    sys.exit(1)
origin = args[args.index("-server") + 1]
dest = pathlib.Path(args[args.index("-session-file") + 1])
fd = os.open(dest, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"origin":origin, "token":os.environ["COSIFT_TOKEN"], "expires":"2030-01-01T00:00:00Z"}, f)
print('{"logged_in":true}')
''')

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o700)

    def run_install(self, *extra):
        result = subprocess.run(
            ["/bin/sh", str(INSTALLER), "--harness=codex", "--yes", "--no-onboarding", "--no-launch", *extra],
            env=self.env, capture_output=True, text=True, timeout=20,
        )
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        return result

    def test_installed_cli_reuses_in_memory_token(self):
        self.env.update(COSIFT_EMAIL="irrelevant@example.invalid", COSIFT_PASSWORD="irrelevant", COSIFT_SESSION_FILE="irrelevant")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = json.loads(self.session.read_text())
        self.assertEqual(saved["origin"], ORIGIN)
        self.assertEqual(saved["token"], TOKEN)
        self.assertEqual(stat.S_IMODE(self.session.stat().st_mode), 0o600)
        self.assertIn("cosift request -query", result.stdout)

    def test_no_cli_leaves_agent_install_usable(self):
        (self.bin / "cosift").unlink()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("signed CLI release", result.stderr)
        self.assertFalse(self.session.exists())

    def test_explicit_cli_requires_binary(self):
        (self.bin / "cosift").unlink()
        self.assertEqual(self.run_install("--cli").returncode, 5)

    def test_no_cli_flag_skips_handoff(self):
        self.assertEqual(self.run_install("--no-cli").returncode, 0)
        self.assertFalse(self.session.exists())
        self.assertFalse(Path(self.env["CLI_CALL_LOG"]).exists())

    def test_dry_run_does_not_invoke_cli(self):
        result = self.run_install("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.session), result.stdout)
        self.assertFalse(self.session.exists())
        self.assertFalse(Path(self.env["CLI_CALL_LOG"]).exists())

    def test_release_defaults_use_production_origins_without_network(self):
        self.env.pop("COSIFT_AUTH_BASE")
        self.env.pop("COSIFT_MCP_URL")
        result = self.run_install("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("https://cosift-mcp-udik5erlkq-uw.a.run.app/v1/mcp", result.stdout)
        help_result = self.run_install("--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("cosift-install 0.4.0", help_result.stdout)
        self.assertIn("https://cosift-auth-udik5erlkq-uw.a.run.app", help_result.stdout)
        self.assertFalse(self.session.exists())
        self.assertFalse(Path(self.env["CLI_CALL_LOG"]).exists())

    def test_existing_session_is_never_overwritten(self):
        self.session.parent.mkdir(parents=True)
        self.session.write_text("keep this existing credential")
        result = self.run_install("--cli")
        self.assertEqual(result.returncode, 5)
        self.assertEqual(self.session.read_text(), "keep this existing credential")
        self.assertFalse(Path(self.env["CLI_CALL_LOG"]).exists())

    def test_symlink_session_is_never_followed(self):
        self.session.parent.mkdir(parents=True)
        destination = self.root / "untouched"
        destination.write_text("keep")
        self.session.symlink_to(destination)
        self.assertEqual(self.run_install("--cli").returncode, 5)
        self.assertEqual(destination.read_text(), "keep")

    def test_cli_failure_is_redacted_and_does_not_break_agents(self):
        self.env["CLI_FAIL"] = "1"
        result = self.run_install()
        self.assertEqual(result.returncode, 0)
        self.assertIn("could not connect", result.stderr)
        self.assertFalse(self.session.exists())
        self.assertEqual(self.run_install("--cli").returncode, 5)

    def test_conflicting_flags_fail_before_handoff(self):
        self.assertEqual(self.run_install("--cli", "--no-cli").returncode, 2)
        self.assertFalse(Path(self.env["CLI_CALL_LOG"]).exists())

    @unittest.skipUnless(os.environ.get("COSIFT_TEST_CLI"), "set COSIFT_TEST_CLI to test the real compiled CLI")
    def test_real_cli_handoff_and_default_request(self):
        calls = []
        class API(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                calls.append(self.path)
                if self.path == "/api/me":
                    valid = self.headers.get("Authorization") == "Bearer " + TOKEN
                    payload = {"id":"fixture-account"}
                elif self.path == "/api/credits":
                    valid = self.headers.get("Cookie") == "cosift_session=" + TOKEN
                    payload = {"balance":7}
                else:
                    valid = False
                    payload = {}
                body = json.dumps(payload).encode()
                self.send_response(200 if valid else 401)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        api = ThreadingHTTPServer(("127.0.0.1", 0), API)
        thread = threading.Thread(target=api.serve_forever, daemon=True)
        thread.start()
        try:
            self.env["COSIFT_COMMUNITY_URL"] = "http://127.0.0.1:" + str(api.server_port)
            (self.bin / "cosift").unlink()
            (self.bin / "cosift").symlink_to(os.environ["COSIFT_TEST_CLI"])
            installed = self.run_install("--cli")
            self.assertEqual(installed.returncode, 0, installed.stderr)
            command = subprocess.run(
                [str(self.bin / "cosift"), "contribute", "-credits"], cwd=self.home,
                env=self.env, capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(command.returncode, 0, command.stderr)
            self.assertEqual(json.loads(command.stdout)["balance"], 7)
            self.assertEqual(calls, ["/api/me", "/api/credits"])
            self.assertEqual(stat.S_IMODE(self.session.stat().st_mode), 0o600)
        finally:
            api.shutdown()
            api.server_close()
            thread.join(timeout=5)


unittest.main()
PY
