#!/bin/sh
# Offline tests for fetching the signed Cosift CLI. Releases are fabricated and served from
# 127.0.0.1; no real release host, harness configuration or credential is touched.
set -eu
exec python3 - "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
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
VERSION = "v9.9.9"
REAL_CURL = shutil.which("curl")
MINISIGN = shutil.which("minisign")
TOOLS = (
    "awk basename cat chmod cp curl cut date dirname grep head id ls mkdir mktemp mv od "
    "python3 rm rmdir sed sh sha256sum shasum sort tail tr wc"
).split()

FAKE_CLI = f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
args = sys.argv[1:]
if args == ["version"]:
    print("cosift fabricated")
    sys.exit(0)
if args == ["login", "-help"]:
    print("  -session-file string", file=sys.stderr)
    sys.exit(2)
assert args[0] == "login", args
assert os.environ["COSIFT_TOKEN"] == os.environ["TEST_TOKEN"]
dest = pathlib.Path(args[args.index("-session-file") + 1])
fd = os.open(dest, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"origin": args[args.index("-server") + 1], "token": os.environ["COSIFT_TOKEN"]}, f)
print('{"logged_in":true}')
'''

FAKE_CURL = f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
args = sys.argv[1:]
base = os.environ["COSIFT_RELEASE_BASE"]
if any(a.startswith(base) for a in args):
    os.execv(os.environ["REAL_CURL"], [os.environ["REAL_CURL"]] + args)
out = pathlib.Path(args[args.index("-o") + 1])
out.write_text(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {}}))
print("200", end="")
'''


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class ReleaseServer:
    def __init__(self, root):
        self.root = Path(root)
        self.requests = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                outer.requests.append((self.path, dict(self.headers)))
                target = outer.root / self.path.lstrip("/")
                if not target.is_file():
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                body = target.read_bytes()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.httpd.server_port}"

    def paths(self):
        return [path for path, _ in self.requests]

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


class CLIInstallCase(unittest.TestCase):
    OS, ARCH, ASSET = "Linux", "x86_64", "cosift-linux-amd64"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.release = self.root / "release"
        self.release.mkdir()
        self.server = ReleaseServer(self.release)
        self.addCleanup(self.server.stop)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.build_tools(with_minisign=bool(MINISIGN))
        self.session = self.home / "config/cosift/community-session.json"
        self.installed = self.home / ".local/bin/cosift"
        config = self.home / ".codex/config.toml"
        config.parent.mkdir()
        config.write_text(
            '# >>> cosift (managed by cosift-install — do not edit)\n'
            '[mcp_servers.cosift]\nurl = "https://mcp.example.invalid/v1/mcp"\n'
            '[mcp_servers.cosift.http_headers]\nAuthorization = "Bearer ' + TOKEN + '"\n'
            '# <<< cosift\n'
        )
        config.chmod(0o600)
        (self.tools / "codex").write_text("#!/bin/sh\nexit 0\n")
        (self.tools / "codex").chmod(0o755)
        self.env = {
            "PATH": str(self.tools),
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / "config"),
            "COSIFT_COMMUNITY_URL": ORIGIN,
            "COSIFT_AUTH_BASE": "https://auth.example.invalid",
            "COSIFT_MCP_URL": "https://mcp.example.invalid/v1/mcp",
            "COSIFT_RELEASE_BASE": self.server.base,
            "REAL_CURL": REAL_CURL,
            "TEST_TOKEN": TOKEN,
            "NO_COLOR": "1",
        }

    def build_tools(self, with_minisign):
        names = list(TOOLS) + (["minisign"] if with_minisign else [])
        for name in names:
            found = shutil.which(name)
            if found and name != "curl":
                (self.tools / name).symlink_to(found)
        for name, body in (
            ("curl", FAKE_CURL),
            ("uname", '#!/bin/sh\ncase "$1" in -s) echo "$FAKE_OS" ;; -m) echo "$FAKE_ARCH" ;; esac\n'),
        ):
            (self.tools / name).write_text(body)
            (self.tools / name).chmod(0o755)

    def publish(self, asset=None, payload=FAKE_CLI, sha_override=None):
        asset = asset or self.ASSET
        data = payload.encode()
        (self.release / asset).write_bytes(data)
        digest = sha_override or sha256(data)
        (self.release / f"{asset}.sha256").write_text(f"{digest}  {asset}\n")
        return data

    def run_install(self, *extra, base=None):
        env = dict(self.env, FAKE_OS=self.OS, FAKE_ARCH=self.ARCH)
        if base is not None:
            env["COSIFT_RELEASE_BASE"] = base
        result = subprocess.run(
            ["/bin/sh", str(INSTALLER), "--harness=codex", "--yes", "--no-onboarding", "--no-launch", *extra],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        return result

    def without_minisign(self):
        (self.tools / "minisign").unlink(missing_ok=True)


class FreshInstall(CLIInstallCase):
    def test_fresh_install_fetches_checks_installs_and_connects(self):
        data = self.publish()
        self.without_minisign()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed.read_bytes(), data)
        self.assertEqual(stat.S_IMODE(self.installed.stat().st_mode), 0o755)
        saved = json.loads(self.session.read_text())
        self.assertEqual(saved["origin"], ORIGIN)
        self.assertEqual(sorted(self.server.paths()), sorted([f"/{self.ASSET}", f"/{self.ASSET}.sha256"]))

    def test_no_credential_is_sent_to_the_release_host(self):
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        for _, headers in self.server.requests:
            self.assertEqual({k.lower() for k in headers} & {"authorization", "cookie", "x-cosift-test"}, set())

    def test_checksum_mismatch_installs_nothing(self):
        self.publish(sha_override="0" * 64)
        self.without_minisign()
        result = self.run_install()
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(self.installed.exists())
        self.assertFalse(self.session.exists())
        self.assertIn("checksum", result.stderr)

    def test_no_cli_download_uses_the_cosift_on_path(self):
        (self.tools / "cosift").write_text(FAKE_CLI)
        (self.tools / "cosift").chmod(0o755)
        result = self.run_install("--no-cli-download")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.requests, [])
        self.assertFalse(self.installed.exists())
        self.assertTrue(self.session.exists())

    def test_no_cli_skips_the_download_too(self):
        self.publish()
        result = self.run_install("--no-cli")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Fetching", result.stdout)
        self.assertEqual(self.server.requests, [])
        self.assertFalse(self.installed.exists())

    def test_a_malformed_checksum_file_installs_nothing(self):
        self.publish()
        self.without_minisign()
        for text in ("<html>not found</html>\n", "abc123  cosift-linux-amd64\n"):
            (self.release / f"{self.ASSET}.sha256").write_text(text)
            result = self.run_install()
            self.assertEqual(result.returncode, 5, result.stderr)
            self.assertIn("malformed", result.stderr)
            self.assertFalse(self.installed.exists())


class ReleaseBase(CLIInstallCase):
    def test_plain_http_to_a_remote_host_is_refused(self):
        self.publish()
        result = self.run_install(base="http://release.example.invalid")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(self.installed.exists())

    def test_userinfo_cannot_pose_as_localhost(self):
        result = self.run_install(base="http://127.0.0.1:80@release.example.invalid")
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_a_trailing_slash_is_accepted(self):
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install(base=self.server.base + "/").returncode, 0)
        self.assertTrue(self.installed.exists())


unittest.main()
PY
