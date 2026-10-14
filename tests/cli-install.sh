#!/bin/sh
# Offline tests for fetching the signed Cosift CLI. Releases are fabricated and served from
# 127.0.0.1; no real release host, harness configuration or credential is touched.
set -eu
exec python3 - "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
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
    "awk basename cat chmod cmp cp curl cut date dirname grep head id ls mkdir mktemp mv od "
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
            found = sys.executable if name == "python3" else shutil.which(name)
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

    ONBOARDING = "--no-onboarding"

    def run_install(self, *extra, base=None):
        env = dict(self.env, FAKE_OS=self.OS, FAKE_ARCH=self.ARCH)
        if base is not None:
            env["COSIFT_RELEASE_BASE"] = base
        result = subprocess.run(
            ["/bin/sh", str(INSTALLER), "--harness=codex", "--yes", self.ONBOARDING, "--no-launch", *extra],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        return result

    def run_uninstall(self):
        env = dict(self.env, FAKE_OS=self.OS, FAKE_ARCH=self.ARCH)
        return subprocess.run(
            ["/bin/sh", str(INSTALLER), "--uninstall", "--yes"],
            env=env, capture_output=True, text=True, timeout=60,
        )

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
        self.env["COSIFT_EXTRA_HEADER"] = "X-Cosift-Test: s3cret"
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        for _, headers in self.server.requests:
            self.assertEqual({k.lower() for k in headers} & {"authorization", "cookie", "x-cosift-test"}, set())

    def test_a_curlrc_does_not_apply_to_the_release_fetch(self):
        self.publish()
        self.without_minisign()
        (self.home / ".curlrc").write_text("header = \"X-Cosift-Test: from-curlrc\"\n")
        self.assertEqual(self.run_install().returncode, 0)
        self.assertEqual(len(self.server.requests), 2)
        for _, headers in self.server.requests:
            self.assertNotIn("x-cosift-test", {k.lower() for k in headers})

    def test_checksum_mismatch_installs_nothing(self):
        self.publish(sha_override="0" * 64)
        self.without_minisign()
        result = self.run_install()
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(self.installed.exists())
        self.assertFalse(self.session.exists())
        self.assertIn("checksum", result.stderr)

    def test_without_minisign_the_checksum_alone_is_trusted_with_a_notice(self):
        data = self.publish()
        self.without_minisign()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed.read_bytes(), data)
        self.assertIn("minisign is not installed", result.stderr)
        self.assertNotIn(f"/{self.ASSET}.minisig", self.server.paths())

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


class Uninstall(CLIInstallCase):
    def installed_state(self):
        return json.loads((self.home / "config/cosift/state.json").read_text())

    def install_and_uninstall(self):
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        return self.run_uninstall()

    def test_the_contributor_skill_is_installed_and_removed(self):
        self.publish()
        self.without_minisign()
        result = self.run_install()
        skill = self.home / ".agents/skills/cosift-contribute/SKILL.md"
        self.assertTrue(skill.is_file(), result.stdout)
        self.assertIn("contributor skill: wrote", result.stdout)
        self.assertNotIn("does not match", result.stderr)
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertFalse(skill.exists())

    def test_install_records_the_binary_path_and_hash(self):
        data = self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        state = self.installed_state()
        self.assertEqual(state["cli_path"], str(self.installed))
        self.assertEqual(state["cli_sha256"], sha256(data))
        self.assertEqual(state["cli_backup"], "")

    def test_an_unchanged_binary_is_removed(self):
        result = self.install_and_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.installed.exists())
        self.assertIn("removed", result.stdout)
        self.assertTrue(self.session.exists())

    def test_a_rerun_keeps_the_record(self):
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        before = self.installed_state()
        self.assertEqual(self.run_install().returncode, 0)
        after = self.installed_state()
        self.assertEqual((after["cli_path"], after["cli_sha256"]), (before["cli_path"], before["cli_sha256"]))
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertFalse(self.installed.exists())

    def test_a_modified_binary_is_kept_with_a_notice(self):
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        self.installed.write_text(FAKE_CLI + "# edited\n")
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed.read_text(), FAKE_CLI + "# edited\n")
        self.assertIn("kept", result.stdout)
        self.assertIn("no longer the binary we installed", result.stdout)

    def test_a_symlink_in_place_of_the_binary_is_kept(self):
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        target = self.root / "elsewhere-cosift"
        target.write_bytes(self.installed.read_bytes())
        self.installed.unlink()
        self.installed.symlink_to(target)
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.installed.is_symlink())
        self.assertTrue(target.exists())
        self.assertIn("symlink", result.stdout)

    def test_a_binary_we_did_not_place_is_not_removed(self):
        data = self.publish()
        self.without_minisign()
        self.installed.parent.mkdir(parents=True)
        self.installed.write_bytes(data)
        self.installed.chmod(0o755)
        self.assertEqual(self.run_install().returncode, 0)
        self.assertEqual(self.installed_state()["cli_path"], "")
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertEqual(self.installed.read_bytes(), data)

    def test_the_backup_of_a_replaced_binary_is_restored(self):
        old = b"#!/bin/sh\necho old\n"
        self.publish()
        self.without_minisign()
        self.installed.parent.mkdir(parents=True)
        self.installed.write_bytes(old)
        self.installed.chmod(0o755)
        self.assertEqual(self.run_install().returncode, 0)
        self.assertNotEqual(self.installed.read_bytes(), old)
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed.read_bytes(), old)
        self.assertEqual(stat.S_IMODE(self.installed.stat().st_mode), 0o755)

    def test_a_missing_backup_just_removes_the_binary(self):
        self.publish()
        self.without_minisign()
        self.installed.parent.mkdir(parents=True)
        self.installed.write_bytes(b"#!/bin/sh\necho old\n")
        self.assertEqual(self.run_install().returncode, 0)
        for backup in self.installed.parent.glob("cosift.cosift-backup-*"):
            backup.unlink()
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertFalse(self.installed.exists())

    def test_a_second_replacement_still_restores_the_original(self):
        old = b"#!/bin/sh\necho old\n"
        self.publish()
        self.without_minisign()
        self.installed.parent.mkdir(parents=True)
        self.installed.write_bytes(old)
        self.assertEqual(self.run_install().returncode, 0)
        self.publish(payload=FAKE_CLI + "# v2\n")
        self.assertEqual(self.run_install().returncode, 0)
        self.assertEqual(self.installed.read_text(), FAKE_CLI + "# v2\n")
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertEqual(self.installed.read_bytes(), old)

    def test_a_state_path_elsewhere_is_not_followed(self):
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        other = self.root / "precious"
        other.write_bytes(self.installed.read_bytes())
        state_file = self.home / "config/cosift/state.json"
        state_file.write_text(state_file.read_text().replace(str(self.installed), str(other)))
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertTrue(other.exists())


class OnboardedState:
    ONBOARDING = "--onboarding"
    SEP = ": "

    def state_text(self):
        return (self.home / "config/cosift/state.json").read_text()

    def complete(self, *args):
        env = dict(self.env, FAKE_OS=self.OS, FAKE_ARCH=self.ARCH)
        cmd = self.home / ".local/bin/cosift-onboarding"
        result = subprocess.run(["/bin/sh", str(cmd), "complete", *args], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'"cli_path"{self.SEP}"', self.state_text())

    def install_and_complete(self, *args):
        self.publish()
        self.without_minisign()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.complete(*args)

    def test_an_unchanged_binary_is_removed_after_the_interview(self):
        self.install_and_complete()
        result = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.installed.exists())

    def test_an_unchanged_binary_is_removed_after_the_interview_is_declined(self):
        self.install_and_complete("--declined")
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertFalse(self.installed.exists())

    def test_a_rerun_with_a_current_binary_keeps_the_record_after_the_interview(self):
        old = b"#!/bin/sh\necho old\n"
        self.installed.parent.mkdir(parents=True)
        self.installed.write_bytes(old)
        self.install_and_complete()
        before = json.loads(self.state_text())
        self.assertNotEqual(before["cli_backup"], "")
        self.assertEqual(self.run_install().returncode, 0)
        after = json.loads(self.state_text())
        for key in ("cli_path", "cli_sha256", "cli_backup"):
            self.assertEqual(after[key], before[key], key)
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertEqual(self.installed.read_bytes(), old)

    def test_a_newer_release_after_the_interview_still_restores_the_original(self):
        old = b"#!/bin/sh\necho old\n"
        self.installed.parent.mkdir(parents=True)
        self.installed.write_bytes(old)
        self.install_and_complete()
        self.publish(payload=FAKE_CLI + "# v2\n")
        self.assertEqual(self.run_install().returncode, 0)
        self.assertEqual(self.installed.read_text(), FAKE_CLI + "# v2\n")
        self.assertEqual(self.run_uninstall().returncode, 0)
        self.assertEqual(self.installed.read_bytes(), old)


class OnboardedWithPython(OnboardedState, CLIInstallCase):
    def test_the_interview_leaves_state_pretty_printed(self):
        self.install_and_complete()
        self.assertIn('\n  "onboarded": true', self.state_text())


class OnboardedWithoutPython(OnboardedState, CLIInstallCase):
    SEP = ":"

    def setUp(self):
        super().setUp()
        (self.tools / "python3").unlink()

    def test_the_interview_leaves_state_on_one_line(self):
        self.install_and_complete()
        self.assertEqual(self.state_text().count("\n"), 1)


class ReleaseBase(CLIInstallCase):
    def test_plain_http_to_a_remote_host_is_refused(self):
        self.publish()
        result = self.run_install(base="http://release.example.invalid")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(self.installed.exists())

    def test_userinfo_cannot_pose_as_localhost(self):
        result = self.run_install(base="http://127.0.0.1:80@release.example.invalid")
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_a_host_that_only_starts_like_localhost_is_refused(self):
        self.env["COSIFT_RELEASE_PUBKEY"] = PINNED_KEY
        for base in ("http://localhost.attacker.example", "http://127.0.0.1.example.invalid"):
            with self.subTest(base=base):
                result = self.run_install(base=base)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(self.server.requests, [])

    def test_a_trailing_slash_is_accepted(self):
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install(base=self.server.base + "/").returncode, 0)
        self.assertTrue(self.installed.exists())


class Lifecycle(CLIInstallCase):
    def test_rerun_with_a_current_binary_downloads_no_binary(self):
        self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        before = self.installed.stat()
        self.session.unlink()
        self.server.requests.clear()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.paths(), [f"/{self.ASSET}.sha256"])
        after = self.installed.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        self.assertEqual(list(self.installed.parent.glob("cosift.cosift-backup-*")), [])
        self.assertIn("already current", result.stdout)
        self.assertTrue(self.session.exists())

    def test_an_older_binary_is_replaced_after_a_backup(self):
        data = self.publish()
        self.without_minisign()
        self.installed.parent.mkdir(parents=True)
        self.installed.write_bytes(b"#!/bin/sh\necho old\n")
        self.installed.chmod(0o755)
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed.read_bytes(), data)
        backups = list(self.installed.parent.glob("cosift.cosift-backup-*"))
        self.assertEqual([b.read_bytes() for b in backups], [b"#!/bin/sh\necho old\n"])

    def test_offline_fresh_install_leaves_the_agents_connected(self):
        before = (self.home / ".codex/config.toml").read_text()
        result = self.run_install(base="http://127.0.0.1:1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.installed.exists())
        self.assertFalse(self.session.exists())
        self.assertIn("Could not fetch", result.stderr)
        self.assertEqual((self.home / ".codex/config.toml").read_text(), before)

    def test_offline_fresh_install_fails_when_the_cli_is_required(self):
        self.assertEqual(self.run_install("--cli", base="http://127.0.0.1:1").returncode, 5)

    def test_offline_rerun_keeps_and_connects_the_installed_binary(self):
        data = self.publish()
        self.without_minisign()
        self.assertEqual(self.run_install().returncode, 0)
        self.session.unlink()
        result = self.run_install(base="http://127.0.0.1:1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed.read_bytes(), data)
        self.assertIn("already installed", result.stderr)
        self.assertTrue(self.session.exists())

    def test_a_missing_binary_asset_is_unavailable_not_installed(self):
        self.publish()
        self.without_minisign()
        (self.release / self.ASSET).unlink()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.installed.exists())

    def install_old_binary(self):
        self.installed.parent.mkdir(parents=True)
        self.installed.write_text(FAKE_CLI)
        self.installed.chmod(0o755)

    def assert_old_binary_untouched(self):
        self.assertEqual(self.installed.read_text(), FAKE_CLI)
        self.assertEqual(list(self.installed.parent.glob("cosift.cosift-backup-*")), [])

    def test_a_refused_download_leaves_the_installed_binary_in_place(self):
        self.publish(payload=FAKE_CLI + "# new\n", sha_override="0" * 64)
        self.without_minisign()
        self.install_old_binary()
        self.assertEqual(self.run_install().returncode, 5)
        self.assert_old_binary_untouched()

    def test_a_failed_binary_download_keeps_and_connects_the_installed_binary(self):
        self.publish(payload=FAKE_CLI + "# new\n")
        self.without_minisign()
        (self.release / self.ASSET).unlink()
        self.install_old_binary()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_old_binary_untouched()
        self.assertIn("already installed", result.stderr)
        self.assertTrue(self.session.exists())

    def test_a_symlinked_binary_is_left_alone_and_connected(self):
        self.publish()
        self.without_minisign()
        target = self.root / "elsewhere-cosift"
        target.write_text(FAKE_CLI)
        target.chmod(0o755)
        self.installed.parent.mkdir(parents=True)
        self.installed.symlink_to(target)
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.requests, [])
        self.assertTrue(self.installed.is_symlink())
        self.assertEqual(target.read_text(), FAKE_CLI)
        self.assertTrue(self.session.exists())


FAKE_SHASUM = f"#!{sys.executable}\n" + '''
import hashlib, sys
args = sys.argv[1:]
algo = hashlib.sha256 if args[:2] == ["-a", "256"] else hashlib.sha1
print(algo(open(args[-1], "rb").read()).hexdigest(), args[-1])
'''

FAKE_OPENSSL = f"#!{sys.executable}\n" + '''
import hashlib, sys
args = sys.argv[1:]
assert args[:2] == ["dgst", "-sha256"], args
print(f"SHA2-256({args[-1]})= " + hashlib.sha256(open(args[-1], "rb").read()).hexdigest())
'''


class HashTools(CLIInstallCase):
    def only_hasher(self, name, body):
        for other in ("sha256sum", "shasum", "openssl"):
            (self.tools / other).unlink(missing_ok=True)
        (self.tools / name).write_text(body)
        (self.tools / name).chmod(0o755)
        data = self.publish()
        self.without_minisign()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed.read_bytes(), data)

    def test_shasum_is_asked_for_sha256(self):
        self.only_hasher("shasum", FAKE_SHASUM)

    def test_openssl_is_asked_for_sha256(self):
        self.only_hasher("openssl", FAKE_OPENSSL)

    def test_no_hashing_tool_installs_nothing(self):
        for other in ("sha256sum", "shasum", "openssl"):
            (self.tools / other).unlink(missing_ok=True)
        self.publish()
        self.without_minisign()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.installed.exists())
        self.assertIn("cannot be checked", result.stderr)


class Platforms(CLIInstallCase):
    def test_each_platform_fetches_its_own_asset(self):
        for system, machine, asset in (
            ("Linux", "x86_64", "cosift-linux-amd64"),
            ("Linux", "aarch64", "cosift-linux-arm64"),
            ("Darwin", "x86_64", "cosift-darwin-amd64"),
            ("Darwin", "arm64", "cosift-darwin-arm64"),
        ):
            with self.subTest(system=system, machine=machine):
                shutil.rmtree(self.home / ".local", ignore_errors=True)
                self.session.unlink(missing_ok=True)
                self.server.requests.clear()
                self.OS, self.ARCH = system, machine
                self.publish(asset=asset)
                self.without_minisign()
                result = self.run_install()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"/{asset}", self.server.paths())
                self.assertEqual(len(self.server.requests), 2)
                self.assertTrue(self.installed.exists())

    def test_an_unsupported_platform_gets_no_download(self):
        self.OS, self.ARCH = "FreeBSD", "amd64"
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.requests, [])
        self.assertIn("no Cosift CLI release", result.stderr)
        self.assertEqual(self.run_install("--cli").returncode, 5)

    def test_windows_is_refused_before_anything_is_written(self):
        before = (self.home / ".codex/config.toml").read_text()
        for system in ("MINGW64_NT-10.0-22631", "MSYS_NT-10.0", "CYGWIN_NT-10.0", "Windows_NT"):
            with self.subTest(system=system):
                self.OS = system
                for extra in ((), ("--dry-run",)):
                    result = self.run_install(*extra)
                    self.assertEqual(result.returncode, 3, result.stderr)
                    self.assertIn("Windows", result.stderr)
                self.assertEqual(self.server.requests, [])
                self.assertFalse((self.home / ".local").exists())
                self.assertEqual((self.home / ".codex/config.toml").read_text(), before)


class Reporting(CLIInstallCase):
    def test_dry_run_describes_the_fetch_and_makes_none(self):
        result = self.run_install("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.ASSET, result.stdout)
        self.assertIn(self.server.base, result.stdout)
        self.assertIn(str(self.installed), result.stdout)
        self.assertEqual(self.server.requests, [])
        self.assertFalse((self.home / ".local").exists())

    def test_the_path_hint_appears_only_when_the_install_dir_is_not_on_path(self):
        self.publish()
        self.without_minisign()
        self.assertIn("export PATH", self.run_install().stdout)
        shutil.rmtree(self.home / ".local")
        self.session.unlink()
        self.env["PATH"] += ":" + str(self.home / ".local/bin")
        self.assertNotIn("export PATH", self.run_install().stdout)

    def test_another_cosift_earlier_on_path_is_named(self):
        self.publish()
        self.without_minisign()
        (self.tools / "cosift").write_text(FAKE_CLI)
        (self.tools / "cosift").chmod(0o755)
        self.env["PATH"] += ":" + str(self.home / ".local/bin")
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(self.tools / "cosift"), result.stderr)
        self.assertIn(str(self.installed), result.stderr)

    def test_the_installed_cosift_first_on_path_needs_no_notice(self):
        self.publish()
        self.without_minisign()
        self.env["PATH"] = str(self.home / ".local/bin") + ":" + self.env["PATH"]
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("is not the one", result.stderr)

    def test_help_documents_the_flag_and_the_overrides(self):
        text = self.run_install("--help").stdout
        for needle in ("--no-cli-download", "COSIFT_RELEASE_BASE", "COSIFT_RELEASE_PUBKEY"):
            self.assertIn(needle, text)


PINNED_KEY = "RWSmd6QcwOKEYVXr/z69ZerbdM2NBNNx49oESn3U5jqniaw/71P3ppdz"

FAKE_MINISIGN = "#!/bin/sh\n" + '''
printf '%s\\n' "$*" >>"$MINISIGN_LOG"
while [ $# -gt 0 ]; do
  case "$1" in -m) file=$2 ;; esac
  shift
done
printf 'Signature and comment signature verified\\nTrusted comment: %s\\n' "${FAKE_TC:-cosift v9.9.9 $(basename "$file")}"
exit "${FAKE_RC:-0}"
'''


@unittest.skipUnless(MINISIGN, "minisign is needed to sign the fabricated releases")
class Signed(CLIInstallCase):
    def setUp(self):
        super().setUp()
        keys = self.root / "keys"
        keys.mkdir()
        self.pub, self.sec = self.keygen(keys, "good")
        self.env["COSIFT_RELEASE_PUBKEY"] = self.pub

    def keygen(self, directory, name):
        subprocess.run(
            [MINISIGN, "-G", "-W", "-f", "-p", str(directory / f"{name}.pub"), "-s", str(directory / f"{name}.key")],
            check=True, capture_output=True,
        )
        return (directory / f"{name}.pub").read_text().splitlines()[1], directory / f"{name}.key"

    def sign(self, asset=None, key=None, comment=None):
        asset = asset or self.ASSET
        comment = comment or f"cosift {VERSION} {asset}"
        subprocess.run(
            [MINISIGN, "-S", "-s", str(key or self.sec), "-m", str(self.release / asset),
             "-x", str(self.release / f"{asset}.minisig"), "-t", comment],
            check=True, capture_output=True,
        )

    def test_a_signed_release_is_verified_and_installed(self):
        data = self.publish()
        self.sign()
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.installed.read_bytes(), data)
        self.assertIn(f"/{self.ASSET}.minisig", self.server.paths())
        self.assertNotIn("minisign is not installed", result.stderr)

    def test_a_forged_binary_with_a_matching_checksum_is_refused(self):
        self.publish()
        self.sign()
        self.publish(payload=FAKE_CLI + "# backdoor\n")
        result = self.run_install()
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(self.installed.exists())
        self.assertFalse(self.session.exists())
        self.assertIn("signature", result.stderr)

    def test_a_release_signed_by_another_key_is_refused(self):
        self.publish()
        _, other = self.keygen(self.root / "keys", "other")
        self.sign(key=other)
        result = self.run_install()
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(self.installed.exists())

    def test_a_signature_for_another_platform_is_refused(self):
        self.publish()
        self.sign(comment=f"cosift {VERSION} cosift-darwin-arm64")
        result = self.run_install()
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(self.installed.exists())
        self.assertIn("another file", result.stderr)

    def test_a_valid_signature_does_not_excuse_a_wrong_checksum(self):
        self.publish(sha_override="0" * 64)
        self.sign()
        result = self.run_install()
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(self.installed.exists())

    def test_a_refused_signature_leaves_the_installed_binary_in_place(self):
        self.publish(payload=FAKE_CLI + "# new\n")
        _, other = self.keygen(self.root / "keys", "other")
        self.sign(key=other)
        self.installed.parent.mkdir(parents=True)
        self.installed.write_text(FAKE_CLI)
        self.installed.chmod(0o755)
        self.assertEqual(self.run_install().returncode, 5)
        self.assertEqual(self.installed.read_text(), FAKE_CLI)
        self.assertEqual(list(self.installed.parent.glob("cosift.cosift-backup-*")), [])

    def test_a_refused_cli_still_records_the_configured_agents(self):
        self.publish()
        result = self.run_install()
        self.assertEqual(result.returncode, 5, result.stderr)
        state = json.loads((self.home / "config/cosift/state.json").read_text())
        self.assertEqual(state["harnesses_configured"], ["codex"])
        self.assertIn("--uninstall", result.stderr)
        removed = self.run_uninstall()
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertNotIn(TOKEN, (self.home / ".codex/config.toml").read_text())

    def test_a_missing_signature_is_refused(self):
        self.publish()
        result = self.run_install()
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(self.installed.exists())


class PinnedKey(CLIInstallCase):
    def setUp(self):
        super().setUp()
        (self.tools / "minisign").unlink(missing_ok=True)
        (self.tools / "minisign").write_text(FAKE_MINISIGN)
        (self.tools / "minisign").chmod(0o755)
        self.log = self.root / "minisign.log"
        self.env["MINISIGN_LOG"] = str(self.log)
        self.publish()
        (self.release / f"{self.ASSET}.minisig").write_text("fabricated\n")

    def verified_with(self):
        return self.log.read_text().split("-P ")[1].split()[0]

    def test_the_pinned_key_is_what_verifies_a_release(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.verified_with(), PINNED_KEY)

    def test_only_a_well_formed_trusted_comment_for_this_asset_passes(self):
        for comment in (
            f"cosift v1 v2 {self.ASSET}",
            f"cosift  {self.ASSET}",
            f"cosift v9.9.9 x{self.ASSET}",
            f"release v9.9.9 {self.ASSET}",
            f"cosift v9.9.9 {self.ASSET} extra",
            "",
        ):
            with self.subTest(comment=comment):
                self.env["FAKE_TC"] = comment or "-"
                result = self.run_install()
                self.assertEqual(result.returncode, 5, result.stderr)
                self.assertFalse(self.installed.exists())

    def test_a_failing_minisign_is_a_refusal_whatever_it_printed(self):
        self.env["FAKE_RC"] = "1"
        result = self.run_install()
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertFalse(self.installed.exists())

    def test_the_key_can_be_replaced_only_for_a_localhost_release(self):
        self.env["COSIFT_RELEASE_PUBKEY"] = "RWQreplacedreplacedreplacedreplacedreplacedreplaced"
        self.assertEqual(self.run_install().returncode, 0)
        self.assertEqual(self.verified_with(), self.env["COSIFT_RELEASE_PUBKEY"])
        self.log.unlink()
        result = self.run_install(base="https://release.example.invalid")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse(self.log.exists())


class DocAnchors(unittest.TestCase):
    ROOT = INSTALLER.parent
    LINK = re.compile(r"\]\(([^)#\s]*)#([^)\s]+)\)")

    @staticmethod
    def slug(heading):
        heading = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading)
        heading = heading.replace("`", "").replace("*", "").strip().lower()
        return re.sub(r"[^\w\- ]", "", heading).replace(" ", "-")

    def anchors(self, path):
        seen, found, fenced = {}, set(), False
        for line in path.read_text().splitlines():
            if line.startswith("```"):
                fenced = not fenced
            elif not fenced and (heading := re.match(r"#{1,6}\s+(.*?)\s*#*$", line)):
                base = self.slug(heading.group(1))
                count = seen.get(base, 0)
                seen[base] = count + 1
                found.add(base if count == 0 else f"{base}-{count}")
        return found

    def test_every_anchor_in_the_docs_resolves(self):
        docs = [self.ROOT / "README.md", *sorted((self.ROOT / "docs").glob("*.md"))]
        checked = 0
        for doc in docs:
            fenced = False
            for number, line in enumerate(doc.read_text().splitlines(), 1):
                if line.startswith("```"):
                    fenced = not fenced
                if fenced:
                    continue
                for target, anchor in self.LINK.findall(line):
                    if target.startswith(("http://", "https://")):
                        continue
                    where = doc if not target else (doc.parent / target).resolve()
                    with self.subTest(link=f"{doc.name}:{number} {target}#{anchor}"):
                        self.assertTrue(where.is_file(), f"{target} is not a file")
                        self.assertIn(anchor, self.anchors(where))
                    checked += 1
        self.assertGreater(checked, 10)


unittest.main()
PY
