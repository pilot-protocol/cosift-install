#!/usr/bin/env python3
"""Test stub: stand-in for claude / codex / opencode.

Only used when the real CLI could not be installed into the test image. It
implements ONLY the subcommands the installer contract uses, and announces
itself on stderr on every invocation so a stubbed run can never pass for real.
Dispatch is on argv[0]'s basename.
"""

import json
import os
import re
import sys

try:
    import tomllib
except ImportError:  # pragma: no cover
    tomllib = None

BANNER = "[test-stub] %s: NOT the real vendor CLI\n"


def die(msg, code=1):
    sys.stderr.write(msg.rstrip("\n") + "\n")
    return code


# ---------------------------------------------------------------- JSONC ----
def jsonc_strip(text):
    """Remove // and /* */ comments and trailing commas. Raises ValueError."""
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
    stripped = "".join(out)
    return re.sub(r",(\s*[}\]])", r"\1", stripped)


def jsonc_load(path):
    with open(path, encoding="utf-8") as fh:
        return json.loads(jsonc_strip(fh.read()))


def find_object_span(text, key):
    """Byte span of the {...} value of a top-level-ish "key", comment/string aware."""
    depth = 0
    i, n = 0, len(text)
    key_pat = '"%s"' % key
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
            if depth == 1 and text[i : j + 1] == key_pat:
                k = j + 1
                while k < n and text[k] in " \t\r\n":
                    k += 1
                if k < n and text[k] == ":":
                    k += 1
                    while k < n and text[k] in " \t\r\n":
                        k += 1
                    if k < n and text[k] == "{":
                        start = k
                        d = 0
                        m = k
                        while m < n:
                            ch = text[m]
                            if ch == '"':
                                q = m + 1
                                while q < n:
                                    if text[q] == "\\":
                                        q += 2
                                        continue
                                    if text[q] == '"':
                                        break
                                    q += 1
                                m = q + 1
                                continue
                            if ch == "/" and m + 1 < n and text[m + 1] == "/":
                                while m < n and text[m] != "\n":
                                    m += 1
                                continue
                            if ch == "/" and m + 1 < n and text[m + 1] == "*":
                                e = text.find("*/", m + 2)
                                if e < 0:
                                    raise ValueError("unterminated block comment")
                                m = e + 2
                                continue
                            if ch == "{":
                                d += 1
                            elif ch == "}":
                                d -= 1
                                if d == 0:
                                    return (start, m + 1)
                            m += 1
                        raise ValueError("unbalanced braces")
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
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    return None


# ---------------------------------------------------------------- claude ---
def claude_path():
    return os.path.join(os.path.expanduser("~"), ".claude.json")


def claude_load():
    p = claude_path()
    if not os.path.exists(p):
        return {"migrationVersion": 14, "seenNotifications": {}}, False
    with open(p, encoding="utf-8") as fh:
        raw = fh.read()
    try:
        return json.loads(raw), False
    except ValueError as exc:
        # Real Claude Code quarantines a corrupt file and starts fresh; mimic it
        # so the installer's "refuse, never overwrite" rule stays testable.
        bdir = os.path.join(os.path.expanduser("~"), ".claude", "backups")
        os.makedirs(bdir, exist_ok=True)
        with open(os.path.join(bdir, ".claude.json.corrupted"), "w") as fh:
            fh.write(raw)
        sys.stderr.write(
            "Claude configuration file at %s is corrupted: %s\n" % (p, exc)
        )
        return {"migrationVersion": 14, "seenNotifications": {}}, True


def claude_save(doc):
    with open(claude_path(), "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")


def claude_main(argv):
    if not argv or argv[0] in ("--version", "-v"):
        print("0.0.0-stub (Claude Code)")
        return 0
    if argv[0] != "mcp":
        return die("stub: unsupported claude command %r" % argv[0], 2)
    sub = argv[1] if len(argv) > 1 else ""
    rest = argv[2:]
    scope, transport, headers, positional = "local", "stdio", [], []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in ("--scope", "-s"):
            scope = rest[i + 1]
            i += 2
        elif a.startswith("--scope="):
            scope = a.split("=", 1)[1]
            i += 1
        elif a in ("--transport", "-t"):
            transport = rest[i + 1]
            i += 2
        elif a.startswith("--transport="):
            transport = a.split("=", 1)[1]
            i += 1
        elif a in ("--header", "-H"):
            headers.append(rest[i + 1])
            i += 2
        elif a.startswith("--header="):
            headers.append(a.split("=", 1)[1])
            i += 1
        else:
            positional.append(a)
            i += 1

    doc, was_corrupt = claude_load()
    if scope == "user":
        servers = doc.setdefault("mcpServers", {})
    else:
        proj = doc.setdefault("projects", {}).setdefault(os.getcwd(), {})
        servers = proj.setdefault("mcpServers", {})

    if sub == "add":
        if len(positional) < 2:
            return die("stub: claude mcp add needs <name> <url>", 2)
        name, url = positional[0], positional[1]
        hdrs = {}
        for h in headers:
            if ":" not in h:
                return die('stub: header must be "Name: value"', 2)
            k, v = h.split(":", 1)
            hdrs[k.strip()] = v.strip()
        entry = {"type": "http" if transport == "http" else transport, "url": url}
        if hdrs:
            entry["headers"] = hdrs
        servers[name] = entry
        claude_save(doc)
        print("Added HTTP MCP server %s with URL: %s to %s config" % (name, url, scope))
        return 0
    if sub == "remove":
        if not positional:
            return die("stub: claude mcp remove needs <name>", 2)
        name = positional[0]
        if name not in servers:
            print('No MCP server named "%s" in %s scope' % (name, scope))
            return 1
        del servers[name]
        claude_save(doc)
        print("Removed MCP server %s from %s config" % (name, scope))
        return 0
    if sub == "list":
        allsrv = doc.get("mcpServers", {})
        if not allsrv:
            print("No MCP servers configured. Use `claude mcp add` to add a server.")
            return 0
        for name, e in sorted(allsrv.items()):
            print("%s: %s (%s) - stub, not health-checked" % (name, e.get("url", e.get("command", "")), e.get("type", "")))
        return 0
    if sub == "get":
        if not positional:
            return die("stub: claude mcp get needs <name>", 2)
        name = positional[0]
        e = doc.get("mcpServers", {}).get(name)
        if not e:
            return die('No MCP server named "%s"' % name, 1)
        print("%s:" % name)
        print("  Scope: User config (available in all your projects)")
        print("  Type: %s" % e.get("type", ""))
        print("  URL: %s" % e.get("url", ""))
        if e.get("headers"):
            print("  Headers:")
            for k, v in e["headers"].items():
                print("    %s: %s" % (k, v))
        return 0
    if was_corrupt:
        return 1
    return die("stub: unsupported claude mcp subcommand %r" % sub, 2)


# ----------------------------------------------------------------- codex ---
def codex_config_path():
    home = os.environ.get("CODEX_HOME") or os.path.join(
        os.path.expanduser("~"), ".codex"
    )
    return os.path.join(home, "config.toml")


def codex_main(argv):
    if not argv or argv[0] in ("--version", "-V"):
        print("codex-cli 0.0.0-stub")
        return 0
    if argv[0] != "mcp":
        return die("stub: unsupported codex command %r" % argv[0], 2)
    sub = argv[1] if len(argv) > 1 else ""
    rest = argv[2:]
    path = codex_config_path()
    doc = {}
    if os.path.exists(path):
        if tomllib is None:
            return die("stub: no tomllib available", 1)
        try:
            with open(path, "rb") as fh:
                doc = tomllib.load(fh)
        except Exception as exc:
            return die(
                "Error: failed to load bootstrap configuration\n\nCaused by:\n    %s"
                % exc,
                1,
            )
    servers = doc.get("mcp_servers", {}) or {}
    if sub == "list":
        if "--json" in rest:
            out = []
            for name, e in sorted(servers.items()):
                out.append(
                    {
                        "name": name,
                        "enabled": True,
                        "transport": {
                            "type": "streamable_http" if e.get("url") else "stdio",
                            "url": e.get("url"),
                            "bearer_token_env_var": e.get("bearer_token_env_var"),
                            "http_headers": e.get("http_headers"),
                        },
                    }
                )
            print(json.dumps(out, indent=2))
            return 0
        print("Name    Url    Status")
        for name, e in sorted(servers.items()):
            print("%s  %s  enabled" % (name, e.get("url", "-")))
        return 0
    if sub == "get":
        if not rest:
            return die("stub: codex mcp get needs <name>", 2)
        e = servers.get(rest[0])
        if e is None:
            return die("stub: no such server %r" % rest[0], 1)
        print(rest[0])
        print("  url: %s" % e.get("url", "-"))
        print("  http_headers: %s" % ("*****" if e.get("http_headers") else "-"))
        return 0
    return die("stub: unsupported codex mcp subcommand %r" % sub, 2)


# -------------------------------------------------------------- opencode ---
def opencode_config_path(create=False):
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config"
    )
    d = os.path.join(base, "opencode")
    for name in ("opencode.json", "opencode.jsonc"):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    return os.path.join(d, "opencode.jsonc") if create else None


def opencode_main(argv):
    if not argv or argv[0] in ("--version", "-v"):
        print("0.0.0-stub")
        return 0
    if argv[0] != "mcp":
        return die("stub: unsupported opencode command %r" % argv[0], 2)
    sub = argv[1] if len(argv) > 1 else ""
    rest = argv[2:]

    if sub == "add":
        name, url, headers = None, None, []
        i = 0
        while i < len(rest):
            a = rest[i]
            if a == "--url":
                url = rest[i + 1]
                i += 2
            elif a.startswith("--url="):
                url = a.split("=", 1)[1]
                i += 1
            elif a == "--header":
                headers.append(rest[i + 1])
                i += 2
            elif a.startswith("--header="):
                headers.append(a.split("=", 1)[1])
                i += 1
            elif name is None:
                name = a
                i += 1
            else:
                i += 1
        if not name or not url:
            return die("stub: opencode mcp add needs <name> --url <url>", 2)
        hdrs = {}
        for h in headers:
            if "=" not in h:
                return die("stub: opencode --header must be KEY=VALUE", 2)
            k, v = h.split("=", 1)
            hdrs[k] = v
        path = opencode_config_path(create=True)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if not os.path.exists(path):
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("{\n  \"$schema\": \"https://opencode.ai/config.json\"\n}\n")
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        entry = json.dumps(
            {"type": "remote", "url": url, **({"headers": hdrs} if hdrs else {})},
            indent=2,
        )
        entry = "\n".join(
            ("      " + ln) if k else ln for k, ln in enumerate(entry.splitlines())
        )
        block = '    "%s": %s' % (name, entry)
        try:
            span = find_object_span(text, "mcp")
        except ValueError as exc:
            return die("stub: cannot parse %s: %s" % (path, exc), 1)
        if span is None:
            close = text.rfind("}")
            if close < 0:
                return die("stub: cannot parse %s" % path, 1)
            inner = text[text.find("{") + 1 : close]
            sep = ",\n" if inner.strip() and not inner.rstrip().endswith(",") else "\n"
            text = (
                text[:close].rstrip()
                + sep
                + '  "mcp": {\n'
                + block
                + "\n  }\n"
                + text[close:]
            )
        else:
            close = span[1] - 1
            inner = text[span[0] + 1 : close]
            sep = ",\n" if inner.strip() and not inner.rstrip().endswith(",") else "\n"
            text = text[:close].rstrip() + sep + block + "\n  " + text[close:]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print('MCP server "%s" added to %s' % (name, path))
        return 0

    if sub in ("list", "ls"):
        path = opencode_config_path()
        if path is None:
            print("0 server(s)")
            return 0
        try:
            doc = jsonc_load(path)
        except ValueError as exc:
            return die(
                "Error: Config file at %s is not valid JSON(C): %s" % (path, exc), 1
            )
        servers = doc.get("mcp", {}) or {}
        for name, e in servers.items():
            if not isinstance(e, dict) or e.get("type") not in ("local", "remote"):
                return die(
                    "Error: Configuration is invalid at %s (mcp.%s)" % (path, name), 1
                )
        for name, e in sorted(servers.items()):
            print("  %s  %s" % (name, e.get("url", e.get("command", ""))))
        print("%d server(s)" % len(servers))
        return 0

    return die("stub: unsupported opencode mcp subcommand %r" % sub, 2)


def main():
    who = os.path.basename(sys.argv[0])
    sys.stderr.write(BANNER % who)
    argv = sys.argv[1:]
    if who.startswith("claude"):
        return claude_main(argv)
    if who.startswith("codex"):
        return codex_main(argv)
    if who.startswith("opencode"):
        return opencode_main(argv)
    return die("stub: unknown harness name %r" % who, 2)


if __name__ == "__main__":
    sys.exit(main())
