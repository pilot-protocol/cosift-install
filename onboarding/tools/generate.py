#!/usr/bin/env python3
"""Build the per-harness cosift-onboarding artifacts from interview/BODY.md and profiles/*.json."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath

ARTIFACT = "cosift-onboarding"
FILE_MODE = "0644"
DIR_MODE = "0755"
VERSION_TOKEN = "{{VERSION}}"
BODY_RELPATH = "interview/BODY.md"
GENERATED_RELPATH = "generated"
MANIFEST_NAME = "MANIFEST.json"
GENERATOR_RELPATH = "tools/generate.py"

DENY_TARGETS = ("CLAUDE.md", "AGENTS.md", "AGENTS.override.md", "SOUL.md")
CODEX_ALLOWED = ("description", "name")

PROFILE_REQUIRED = (
    "harness",
    "output_relpath",
    "install_path",
    "owned_dir",
    "shared_parent",
    "frontmatter",
    "allowed_frontmatter_keys",
    "invocation",
    "verified",
)
PROFILE_OPTIONAL = ("banner",)

_PLAIN_BAD_FIRST = set("-?:,[]{}#&*!|>'\"%@`")
_YAML_RESERVED = {"true", "false", "null", "yes", "no", "on", "off", "~", ""}


class GenerateError(Exception):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _looks_numeric(text: str) -> bool:
    try:
        float(text)
    except ValueError:
        return False
    return True


def _plain_safe(text: str) -> bool:
    if text in _YAML_RESERVED or text.lower() in _YAML_RESERVED:
        return False
    if text != text.strip():
        return False
    if text[0] in _PLAIN_BAD_FIRST:
        return False
    if ": " in text or text.endswith(":"):
        return False
    if " #" in text:
        return False
    if any(ch in text for ch in "\n\r\t"):
        return False
    return not _looks_numeric(text)


def yaml_scalar(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if not isinstance(value, str):
        raise GenerateError(f"unsupported frontmatter scalar type {type(value).__name__}")
    return value if _plain_safe(value) else json.dumps(value)


def yaml_block(pairs: list[tuple[str, object]], indent: int = 0) -> list[str]:
    pad = " " * indent
    lines: list[str] = []
    for key, value in pairs:
        if isinstance(value, dict):
            if not value:
                raise GenerateError(f"frontmatter key {key!r} maps to an empty block")
            lines.append(f"{pad}{key}:")
            lines.extend(yaml_block(list(value.items()), indent + 2))
        elif isinstance(value, list):
            if not value:
                raise GenerateError(f"frontmatter key {key!r} maps to an empty sequence")
            lines.append(f"{pad}{key}:")
            lines.extend(f"{pad}  - {yaml_scalar(item)}" for item in value)
        else:
            lines.append(f"{pad}{key}: {yaml_scalar(value)}")
    return lines


def substitute(value: object, version: str) -> object:
    if isinstance(value, str):
        return value.replace(VERSION_TOKEN, version)
    if isinstance(value, list):
        return [substitute(item, version) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item, version) for key, item in value.items()}
    return value


def _frontmatter_pairs(profile: dict) -> list[tuple[str, object]]:
    pairs = []
    for entry in profile["frontmatter"]:
        if not isinstance(entry, list) or len(entry) != 2 or not isinstance(entry[0], str):
            raise GenerateError(f"{profile['harness']}: frontmatter entries must be [key, value]")
        pairs.append((entry[0], entry[1]))
    return pairs


def validate_profile(profile: dict, source: Path) -> None:
    where = source.name
    if not isinstance(profile, dict):
        raise GenerateError(f"{where}: profile must be a JSON object")

    keys = set(profile)
    missing = sorted(set(PROFILE_REQUIRED) - keys)
    unknown = sorted(keys - set(PROFILE_REQUIRED) - set(PROFILE_OPTIONAL))
    if missing:
        raise GenerateError(f"{where}: missing keys {missing}")
    if unknown:
        raise GenerateError(f"{where}: unknown keys {unknown}")

    harness = profile["harness"]
    if not isinstance(harness, str) or not harness:
        raise GenerateError(f"{where}: harness must be a non-empty string")
    if not isinstance(profile["verified"], bool):
        raise GenerateError(f"{where}: verified must be a boolean")
    if not isinstance(profile["invocation"], str) or not profile["invocation"]:
        raise GenerateError(f"{where}: invocation must be a non-empty string")

    banner = profile.get("banner", [])
    if not isinstance(banner, list) or any(not isinstance(line, str) for line in banner):
        raise GenerateError(f"{where}: banner must be a list of strings")

    pairs = _frontmatter_pairs(profile)
    if not pairs:
        raise GenerateError(f"{where}: frontmatter is empty")
    fm_keys = [key for key, _ in pairs]
    if len(set(fm_keys)) != len(fm_keys):
        raise GenerateError(f"{where}: duplicate frontmatter keys")

    allowed = profile["allowed_frontmatter_keys"]
    if not isinstance(allowed, list) or any(not isinstance(key, str) for key in allowed):
        raise GenerateError(f"{where}: allowed_frontmatter_keys must be a list of strings")
    if sorted(allowed) != list(allowed):
        raise GenerateError(f"{where}: allowed_frontmatter_keys must be sorted")
    if set(fm_keys) != set(allowed):
        raise GenerateError(
            f"{where}: frontmatter keys {sorted(fm_keys)} != allowed {sorted(allowed)}"
        )
    if harness == "codex" and tuple(sorted(fm_keys)) != CODEX_ALLOWED:
        raise GenerateError(f"{where}: codex frontmatter accepts only {list(CODEX_ALLOWED)}")

    relpath = profile["output_relpath"]
    if not isinstance(relpath, str) or not relpath:
        raise GenerateError(f"{where}: output_relpath must be a non-empty string")
    parts = PurePosixPath(relpath).parts
    if relpath.startswith("/") or ".." in parts:
        raise GenerateError(f"{where}: output_relpath must be a relative path without '..'")

    install = profile["install_path"]
    shared = profile["shared_parent"]
    owned = profile["owned_dir"]
    for label, value in (("install_path", install), ("shared_parent", shared)):
        if not isinstance(value, str) or not value:
            raise GenerateError(f"{where}: {label} must be a non-empty string")
    if owned is not None and not isinstance(owned, str):
        raise GenerateError(f"{where}: owned_dir must be a string or null")

    for label, value in (("output_relpath", relpath), ("install_path", install)):
        if PurePosixPath(value).name in DENY_TARGETS:
            raise GenerateError(f"{where}: {label} targets a deny-listed instruction file")

    install_dir = str(PurePosixPath(install).parent)
    if owned is None:
        if install_dir != shared:
            raise GenerateError(f"{where}: owned_dir is null so install_path must sit in shared_parent")
    else:
        if owned != install_dir:
            raise GenerateError(f"{where}: owned_dir must be the install_path directory")
        if not owned.startswith(shared + "/"):
            raise GenerateError(f"{where}: owned_dir must sit under shared_parent")


def load_profiles(root: Path) -> list[dict]:
    directory = root / "profiles"
    paths = sorted(directory.glob("*.json"))
    if not paths:
        raise GenerateError(f"no profiles found under {directory}")
    profiles = []
    for path in paths:
        try:
            profile = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise GenerateError(f"{path.name}: invalid JSON ({exc})") from None
        validate_profile(profile, path)
        profiles.append(profile)
    ids = [profile["harness"] for profile in profiles]
    if len(set(ids)) != len(ids):
        raise GenerateError(f"duplicate harness ids in profiles: {sorted(ids)}")
    profiles.sort(key=lambda profile: profile["harness"])
    return profiles


def read_version(root: Path) -> str:
    path = root / "VERSION"
    if not path.is_file():
        raise GenerateError(f"missing {path}")
    version = path.read_text(encoding="utf-8").strip()
    if not version:
        raise GenerateError(f"{path} is empty")
    return version


def read_body(root: Path) -> bytes:
    path = root / BODY_RELPATH
    if not path.is_file():
        raise GenerateError(f"missing {path} (the interview body has not landed yet)")
    body = path.read_bytes()
    if not body.strip():
        raise GenerateError(f"{path} is empty")
    return body


def marker_line(version: str) -> str:
    return (
        f"<!-- generated by {GENERATOR_RELPATH} from {BODY_RELPATH}; "
        f"{ARTIFACT} v{version}; do not edit -->"
    )


def build_prefix(profile: dict, version: str) -> bytes:
    pairs = [(key, substitute(value, version)) for key, value in _frontmatter_pairs(profile)]
    parts = ["---\n"]
    parts.extend(line + "\n" for line in yaml_block(pairs))
    parts.append("---\n")
    parts.append("\n")
    parts.append(marker_line(version) + "\n")
    banner = [substitute(line, version) for line in profile.get("banner", [])]
    if banner:
        parts.append("\n")
        parts.extend(line + "\n" for line in banner)
    parts.append("\n")
    return "".join(parts).encode("utf-8")


def build(root: Path) -> dict[str, bytes]:
    version = read_version(root)
    body = read_body(root)
    body_sha = sha256_bytes(body)
    profiles = load_profiles(root)

    files: dict[str, bytes] = {}
    entries = []
    for profile in profiles:
        prefix = build_prefix(profile, version)
        content = prefix + body
        relpath = f"{profile['harness']}/{profile['output_relpath']}"
        if relpath in files:
            raise GenerateError(f"two profiles generate {relpath}")
        files[relpath] = content
        entries.append(
            {
                "harness": profile["harness"],
                "generated_path": f"{GENERATED_RELPATH}/{relpath}",
                "install_path": profile["install_path"],
                "owned_dir": profile["owned_dir"],
                "shared_parent": profile["shared_parent"],
                "file_mode": FILE_MODE,
                "dir_mode": DIR_MODE,
                "sha256": sha256_bytes(content),
                "body_sha256": body_sha,
                "prefix_bytes": len(prefix),
                "prefix_sha256": sha256_bytes(prefix),
                "frontmatter_keys": [key for key, _ in _frontmatter_pairs(profile)],
                "allowed_frontmatter_keys": list(profile["allowed_frontmatter_keys"]),
                "invocation": profile["invocation"],
                "verified": profile["verified"],
            }
        )

    manifest = {
        "artifact": ARTIFACT,
        "version": version,
        "generator": GENERATOR_RELPATH,
        "generated_root": GENERATED_RELPATH,
        "body_source": BODY_RELPATH,
        "body_sha256": body_sha,
        "file_mode": FILE_MODE,
        "dir_mode": DIR_MODE,
        "harnesses": entries,
    }
    files[MANIFEST_NAME] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    return files


def read_generated(root: Path) -> dict[str, bytes]:
    directory = root / GENERATED_RELPATH
    if not directory.is_dir():
        return {}
    found = {}
    for path in sorted(directory.rglob("*")):
        if path.is_file():
            found[path.relative_to(directory).as_posix()] = path.read_bytes()
    return found


def _diff(relpath: str, expected: bytes, actual: bytes) -> str:
    try:
        left = actual.decode("utf-8").splitlines(keepends=True)
        right = expected.decode("utf-8").splitlines(keepends=True)
    except UnicodeDecodeError:
        return f"  {relpath}: binary difference\n"
    lines = difflib.unified_diff(
        left, right, fromfile=f"a/{relpath} (on disk)", tofile=f"b/{relpath} (regenerated)", n=2
    )
    return "".join(line if line.endswith("\n") else line + "\n" for line in lines)


def cmd_write(root: Path, quiet: bool) -> int:
    files = build(root)
    directory = root / GENERATED_RELPATH
    for relpath in sorted(read_generated(root)):
        if relpath not in files:
            (directory / relpath).unlink()
            print(f"removed stale {GENERATED_RELPATH}/{relpath}")
    for relpath, content in sorted(files.items()):
        target = directory / relpath
        target.parent.mkdir(parents=True, exist_ok=True)
        changed = not target.is_file() or target.read_bytes() != content
        target.write_bytes(content)
        if not quiet and changed:
            print(f"wrote {GENERATED_RELPATH}/{relpath}")
    for path in sorted(directory.rglob("*"), reverse=True):
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()
    if not quiet:
        print(f"{len(files)} files up to date under {GENERATED_RELPATH}/")
    return 0


def cmd_check(root: Path) -> int:
    expected = build(root)
    actual = read_generated(root)
    problems = []
    for relpath in sorted(set(expected) | set(actual)):
        if relpath not in actual:
            problems.append(f"missing {GENERATED_RELPATH}/{relpath}")
        elif relpath not in expected:
            problems.append(f"unexpected {GENERATED_RELPATH}/{relpath}")
        elif actual[relpath] != expected[relpath]:
            problems.append(
                f"stale {GENERATED_RELPATH}/{relpath}\n"
                + _diff(relpath, expected[relpath], actual[relpath])
            )
    if problems:
        print("generated tree does not match the sources:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        print(f"run {GENERATOR_RELPATH} to regenerate", file=sys.stderr)
        return 1
    print(f"generated tree matches the sources ({len(expected)} files)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--check", action="store_true", help="fail on any drift, write nothing")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    root = args.root.resolve()
    try:
        return cmd_check(root) if args.check else cmd_write(root, args.quiet)
    except GenerateError as exc:
        print(f"generate.py: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
