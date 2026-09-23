#!/usr/bin/env python3
"""Read ONE scalar from a Hermes role.yaml: the block-scoped walker.

Usage: role-yaml.py <role.yaml> <key[.subkey[...]]>

This is the only role.yaml scalar reader in the scaffold. `_lib.sh`'s
`yaml_get`, `credential-launch.sh` (the gateway entrypoint, which must not
source `_lib.sh` and its fleet environment) and `heartbeat.sh` all call it, so
they cannot disagree about what a key says.

Every dotted segment is looked up ONLY inside the block its parent opens, at
that block's own indentation, and the lookup stops at the first line that
dedents back out of it. Absent prints nothing. Quotes are removed and a
trailing `# comment` is dropped. A duplicated key, or a parent that is a scalar
rather than a block mapping, is refused on stderr with a nonzero exit instead
of being guessed at. Standard library only: no PyYAML dependency.
"""
import json, pathlib, re, sys

path, dotted = sys.argv[1:3]
try:
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
except FileNotFoundError:
    sys.exit(0)

KEY = re.compile(r"""( *)([A-Za-z0-9_][A-Za-z0-9_.-]*|"[^"]*"|'[^']*'):(?:[ \t]+(.*?))?[ \t]*""")
BLOCK_SCALAR = re.compile(r"[|>][+-]?[0-9]?(?:[ \t]+#.*)?")


def plain(raw):
    """One YAML scalar as text: quotes removed, a trailing comment dropped."""
    raw = (raw or "").strip()
    if not raw or raw.startswith("#"):
        return ""
    if raw[0] == '"':
        m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"(?:[ \t]+#.*)?', raw)
        if not m:
            return raw
        try:
            return json.loads(f'"{m.group(1)}"')
        except ValueError:
            return m.group(1)
    if raw[0] == "'":
        m = re.fullmatch(r"'((?:[^']|'')*)'(?:[ \t]+#.*)?", raw)
        return m.group(1).replace("''", "'") if m else raw
    return re.split(r"[ \t]+#", raw, maxsplit=1)[0].strip()


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def meaningful(line):
    text = line.strip()
    return bool(text) and not text.startswith("#") and text not in ("---", "...")


start, end, parent_indent = 0, len(lines), -1
value = None
parts = dotted.split(".")
for depth, part in enumerate(parts):
    child_indent, hits = None, []
    for index in range(start, end):
        line = lines[index]
        if not meaningful(line):
            continue
        if indent_of(line) <= parent_indent:
            end = index  # the enclosing block ends here; nothing after it is ours
            break
        if child_indent is None:
            child_indent = indent_of(line)
        if indent_of(line) != child_indent:
            continue  # deeper nesting belongs to some other key
        m = KEY.fullmatch(line)
        if m and plain(m.group(2)) == part:
            hits.append((index, m.group(3)))
    if not hits:
        sys.exit(0)  # absent: print nothing
    if len(hits) > 1:
        sys.exit(f"yaml_get: duplicate key {'.'.join(parts[:depth + 1])!r} in {path}")
    index, raw = hits[0]
    if depth < len(parts) - 1:
        if plain(raw) != "":
            sys.exit(f"yaml_get: {'.'.join(parts[:depth + 1])!r} is not a block mapping in {path}")
        start, parent_indent = index + 1, child_indent
        continue
    raw = (raw or "").strip()
    if raw[:1] in ("'", '"') and plain(raw) == raw:
        # A quoted scalar that does not close on its own line continues onto
        # the more-indented lines below it (PyYAML folds long URLs this way).
        for line in lines[index + 1:end]:
            if line.strip() and indent_of(line) <= child_indent:
                break
            if raw.endswith("\\") and raw[0] == '"':
                raw = raw[:-1] + line.lstrip()
            else:
                raw = raw + " " + line.strip()
            if plain(raw) != raw:
                break
    if BLOCK_SCALAR.fullmatch(raw):
        body = []
        for line in lines[index + 1:end]:
            if line.strip() and indent_of(line) <= child_indent:
                break
            body.append(line)
        while body and not body[-1].strip():
            body.pop()
        floor = min((indent_of(l) for l in body if l.strip()), default=0)
        body = [l[floor:] for l in body]
        value = ("\n" if raw[0] == "|" else " ").join(body)
    else:
        value = plain(raw)
print(value if value is not None else "")
