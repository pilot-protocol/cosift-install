#!/usr/bin/env python3
"""Print top-level frontmatter keys of a harness artifact as key<TAB>value lines."""
import sys

path = sys.argv[1]
with open(path, "rb") as fh:
    text = fh.read().decode("utf-8", "replace")

lines = text.split("\n")
if not lines or lines[0].rstrip("\r") != "---":
    sys.stderr.write("no frontmatter: first line is not ---\n")
    sys.exit(1)

end = None
for i in range(1, len(lines)):
    if lines[i].rstrip("\r") == "---":
        end = i
        break
if end is None:
    sys.stderr.write("unterminated frontmatter: no closing ---\n")
    sys.exit(1)

out = []
for raw in lines[1:end]:
    line = raw.rstrip("\r")
    if not line.strip() or line[:1] in (" ", "\t", "-", "#"):
        continue
    if ":" not in line:
        sys.stderr.write("unparsable frontmatter line: %r\n" % line)
        sys.exit(1)
    key, value = line.split(":", 1)
    key = key.strip()
    if not key or not all(c.isalnum() or c in "-_" for c in key):
        sys.stderr.write("unparsable frontmatter key: %r\n" % key)
        sys.exit(1)
    value = value.strip().strip("'\"")
    out.append("%s\t%s" % (key, value.replace("\t", " ")))

sys.stdout.write("\n".join(out) + ("\n" if out else ""))
