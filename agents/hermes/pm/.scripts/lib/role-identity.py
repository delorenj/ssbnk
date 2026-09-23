#!/usr/bin/env python3
"""The named-agent identity a Hermes role.yaml declares, validated, as JSON.

Usage: role-identity.py <role.yaml> <agent_id> <profile_name>

A role.yaml describes a POST (`agent_id`, `profile`: `33god-pm`). Most posts
are held by an unnamed agent and carry no `identity:` block at all; their
identity memory lives in the post-derived compatibility bank `agent-<profile>`.

A NAMED agent is a person-like identity that holds a post and keeps its name,
its personal Hindsight bank and its chat identity if it ever moves to another
post. It declares that in role.yaml:

    identity:
      name: grolf                 # who the agent is; never a post id
      write_bank: agent-grolf     # optional; always agent-<name>
      recall_banks:               # optional; read-only history it may recall
        - agent-grolf
        - agent-33god-pm

Prints `{}` for an unnamed post, otherwise one JSON object with exactly the
keys `name`, `write_bank` and `recall_banks` (write_bank first, deduplicated).
Anything malformed is refused on stderr with a nonzero exit rather than
guessed at: 10-hermes-profile.sh pins the profile's memory from this answer
and 80-registry.sh projects it into the fleet registry, so a wrong guess would
silently move an agent's private memory.
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover - provisioning hosts ship PyYAML
    sys.exit("role-identity: PyYAML is required")

BANK = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}")
# `agent-<name>` must itself be a valid bank id, so a name is at most 58 chars.
NAME = re.compile(r"[a-z0-9][a-z0-9_-]{0,57}")
RESERVED_BANKS = {"custom", "hermes"}
ALLOWED_KEYS = {"name", "write_bank", "recall_banks"}
MAX_RECALL_BANKS = 16


def refuse(message: str) -> "None":
    sys.exit(f"role-identity: {message}")


class UniqueKeyLoader(yaml.SafeLoader):
    """Safe YAML that refuses a duplicated key instead of letting the last one win."""


def _unique_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            refuse(f"role.yaml has a duplicate key {key!r} ({key_node.start_mark})")
        seen.add(key)
    return loader.construct_mapping(node, deep=deep)


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _unique_mapping
)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        refuse("usage: role-identity.py <role.yaml> <agent_id> <profile_name>")
    path, agent_id, profile_name = argv[1:4]
    try:
        document = yaml.load(pathlib.Path(path).read_text(encoding="utf-8"), Loader=UniqueKeyLoader)
    except FileNotFoundError:
        refuse(f"role.yaml not found: {path}")
    except yaml.YAMLError as exc:
        refuse(f"role.yaml is not valid YAML: {exc}")
    if not isinstance(document, dict):
        refuse("role.yaml root must be a mapping")

    block = document.get("identity")
    if block is None:
        print("{}")
        return 0
    if not isinstance(block, dict):
        refuse("identity must be a mapping with a `name`")
    unknown = sorted(set(block) - ALLOWED_KEYS)
    if unknown:
        refuse(f"identity carries unsupported key(s): {', '.join(map(str, unknown))}")

    name = block.get("name")
    if not isinstance(name, str) or NAME.fullmatch(name) is None:
        refuse("identity.name must be a lower-case id ([a-z0-9][a-z0-9_-]*, at most 58 chars)")
    posts = {value for value in (agent_id, profile_name) if value}
    if name in posts:
        # agent-<post> is the compatibility bank the NEXT unnamed holder of this
        # post would be pinned to. A name equal to the post would hand that
        # holder this agent's private memory.
        refuse(f"identity.name {name!r} is a post id; a named agent needs a name of its own")

    expected_bank = f"agent-{name}"
    write_bank = block.get("write_bank", expected_bank)
    if write_bank != expected_bank:
        refuse(f"identity.write_bank must be {expected_bank!r} (a personal bank is named for the agent, never for a post)")

    raw_recall = block.get("recall_banks", [])
    if raw_recall is None:
        raw_recall = []
    if not isinstance(raw_recall, list):
        refuse("identity.recall_banks must be a list of bank ids")
    recall: list[str] = [write_bank]
    for bank in raw_recall:
        if not isinstance(bank, str) or BANK.fullmatch(bank) is None:
            refuse(f"identity.recall_banks entry {bank!r} is not a lower-case bank id")
        if bank in RESERVED_BANKS:
            refuse(f"identity.recall_banks may not name the shared fallback bank {bank!r}")
        if bank not in recall:
            recall.append(bank)
    if len(recall) > MAX_RECALL_BANKS:
        refuse(f"identity.recall_banks names more than {MAX_RECALL_BANKS} banks")

    print(json.dumps({"name": name, "write_bank": write_bank, "recall_banks": recall}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
