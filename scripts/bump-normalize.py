"""Normalise a package file for scripts/bump-reproduces.sh.

    python3 -I bump-normalize.py <version> < file > normalised   (2> resolution line)

Text only, no YAML or JSON parsing of the untrusted file: on the lines that
name @boonty-io/ai-config, the given version becomes V; the importer's two
lines after `'@boonty-io/ai-config':` (specifier, version) get the same
replacement; and the `resolution:` line right after the ai-config entry of
`packages:` is removed from the output and written to stderr, so the caller
checks it apart. Every other byte is kept, so any other change shows.
"""
import re
import sys

version = sys.argv[1]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    sys.exit("bad version")
data = sys.stdin.buffer.read()
try:
    text = data.decode("utf-8")
except UnicodeDecodeError:
    sys.exit("not utf-8")

pkg = "@boonty-io/ai-config"
v = re.escape(version)
lines = text.split("\n")
out = []
after_importer = 0
take_resolution = False
for line in lines:
    stripped = line.strip()
    if take_resolution:
        take_resolution = False
        if stripped.startswith("resolution:"):
            sys.stderr.write(stripped + "\n")
            continue
    if after_importer:
        after_importer -= 1
        line = re.sub(r"^(\s*(?:specifier: \^|version: ))" + v + r"$", r"\1V", line)
    if pkg in line:
        line = re.sub(re.escape(pkg) + "@" + v + r"(?![0-9A-Za-z.])", pkg + "@V", line)
        line = re.sub(r'("' + re.escape(pkg) + r'": "[\^~]?)' + v + '"', r'\1V"', line)
        if stripped == "'" + pkg + "':":
            after_importer = 2
        if re.fullmatch(r"'" + re.escape(pkg) + r"@V':", line.strip()) and line.startswith("  '") and not line.startswith("   "):
            take_resolution = True
    out.append(line)
sys.stdout.write("\n".join(out))
