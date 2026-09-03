#!/usr/bin/env python3
"""Store process-only secrets in 1Password and print op:// references.

Secret values are read from stdin and are never placed in argv, a temporary
file, stdout, or an ``op`` child environment. Item JSON travels only over an
anonymous pipe to the 1Password CLI. Credential pairs are staged in a new,
versioned item and both fields are verified before either reference is emitted.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import uuid


def fail(message: str) -> "None":
    raise SystemExit(f"1Password secret storage failed: {message}")


def op_run(args: list[str], *, payload: str | None = None) -> subprocess.CompletedProcess[str]:
    allowed = (
        "PATH",
        "HOME",
        "USERPROFILE",
        "APPDATA",
        "LOCALAPPDATA",
        "SystemRoot",
        "TMPDIR",
        "TMP",
        "TEMP",
        "XDG_CONFIG_HOME",
        "XDG_RUNTIME_DIR",
        "OP_ACCOUNT",
        "OP_CONNECT_HOST",
        "OP_CONNECT_TOKEN",
        "OP_LOAD_DESKTOP_APP_SETTINGS",
        "OP_SERVICE_ACCOUNT_TOKEN",
    )
    env = {name: os.environ[name] for name in allowed if name in os.environ}
    env.update(
        (name, value)
        for name, value in os.environ.items()
        if name.startswith("OP_SESSION_")
    )
    env["NO_COLOR"] = "1"
    return subprocess.run(
        [OP, *args],
        input=payload,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env=env,
        timeout=30,
    )


OP = shutil.which("op") or ""
if not OP:
    fail("the op CLI is not installed")

if len(sys.argv) == 3 and sys.argv[1] == "--validate-reference":
    reference = sys.argv[2]
    if not reference.startswith("op://") or any(ch in reference for ch in "\r\n\0"):
        fail("invalid 1Password reference")
    resolved = op_run(["read", "--", reference])
    if resolved.returncode != 0 or not resolved.stdout.rstrip("\n"):
        fail("the configured reference did not resolve")
    raise SystemExit(0)

if len(sys.argv) == 4 and sys.argv[1] == "--delete-item-id":
    vault, item_id = sys.argv[2:]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._ -]{0,126}", vault):
        fail("vault name contains unsupported characters")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", item_id):
        fail("invalid immutable item id")
    deleted = op_run(["item", "delete", item_id, "--vault", vault, "--archive"])
    if deleted.returncode != 0:
        fail("staged item cleanup was rejected")
    raise SystemExit(0)

pair_mode = len(sys.argv) == 6 and sys.argv[1] == "--store-pair"
single_staged_mode = len(sys.argv) == 5 and sys.argv[1] == "--store-staged"
staged_mode = pair_mode or single_staged_mode
if pair_mode:
    vault, item, field_one, field_two = sys.argv[2:]
    if field_one == field_two or not all(
        re.fullmatch(r"[a-z][a-z0-9_]{0,63}", field)
        for field in (field_one, field_two)
    ):
        fail("pair field names are invalid or not distinct")
elif single_staged_mode:
    vault, item, field_one = sys.argv[2:]
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", field_one):
        fail("staged field name is invalid")
else:
    if len(sys.argv) != 3:
        fail(
            "usage: store-onepassword-secret.py <vault> <item>, "
            "--store-staged <vault> <item-prefix> <field>, or "
            "--store-pair <vault> <item-prefix> <field-one> <field-two>"
        )
    vault, item = sys.argv[1:]
safe = re.compile(r"[A-Za-z0-9][A-Za-z0-9._ -]{0,126}")
if not safe.fullmatch(vault) or not safe.fullmatch(item):
    fail("vault or item name contains unsupported characters")

payload = sys.stdin.read()
if pair_mode:
    values = payload.split("\n")
    if len(values) != 2 or not all(values):
        fail("credential pair input must contain exactly two non-empty lines")
    secrets = [(field_one, values[0]), (field_two, values[1])]
elif single_staged_mode:
    if payload.endswith("\n"):
        payload = payload[:-1]
    secrets = [(field_one, payload)]
else:
    if payload.endswith("\n"):
        payload = payload[:-1]
    secrets = [("password", payload)]
if any(not value or any(ch in value for ch in "\r\n\0") for _, value in secrets):
    fail("refusing to store an empty or multiline value")

if staged_mode:
    if len(item) > 105:
        fail("item prefix is too long for a versioned item")
    item = f"{item}-v-{uuid.uuid4().hex[:16]}"
    document = {
        "title": item,
        "category": "PASSWORD",
        "fields": [
            {
                "id": field,
                "type": "CONCEALED",
                "label": field,
                "value": value,
            }
            for field, value in secrets
        ]
        + [
            {
                "id": "notesPlain",
                "type": "STRING",
                "purpose": "NOTES",
                "label": "notesPlain",
                "value": (
                    "Managed by hermes-agent-template as a staged credential; "
                    "rotate through the provisioner."
                ),
            }
        ],
    }
    stored = op_run(
        ["item", "create", "--vault", vault, "--format=json", "-"],
        payload=json.dumps(document),
    )
    if stored.returncode != 0:
        fail("op rejected the staged credential update")
    try:
        created = json.loads(stored.stdout)
        item_id = str(created.get("id") or "")
    except (AttributeError, TypeError, json.JSONDecodeError):
        fail("op item create returned invalid JSON")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", item_id):
        fail("op item create omitted an immutable item id")
    references = [f"op://{vault}/{item_id}/{field}" for field, _ in secrets]
    for reference, (_, expected) in zip(references, secrets, strict=True):
        verified = op_run(["read", "--", reference])
        if verified.returncode != 0 or verified.stdout.rstrip("\n") != expected:
            # The item is not active until the caller commits its refs. Archive
            # this failed stage by immutable id; never guess/delete by title.
            op_run(["item", "delete", item_id, "--vault", vault, "--archive"])
            fail("a staged credential field did not verify; cleanup attempted")
    print("\n".join([item_id, *references]))
    raise SystemExit(0)

listed = op_run(["item", "list", "--vault", vault, "--format=json"])
if listed.returncode != 0:
    fail("vault access/authentication was rejected")
try:
    rows = json.loads(listed.stdout)
except (TypeError, json.JSONDecodeError):
    fail("op item list returned invalid JSON")

matches = [row for row in rows if isinstance(row, dict) and row.get("title") == item]
if len(matches) > 1:
    fail("multiple items have the requested title")

if matches:
    item_id = str(matches[0].get("id") or "")
    if not item_id:
        fail("the existing item has no id")
    fetched = op_run(["item", "get", item_id, "--vault", vault, "--format=json"])
    if fetched.returncode != 0:
        fail("the existing item could not be read")
    try:
        document = json.loads(fetched.stdout)
    except (TypeError, json.JSONDecodeError):
        fail("op item get returned invalid JSON")
    fields = document.get("fields")
    if not isinstance(fields, list):
        fail("the existing item has no fields list")
    concealed_field = next(
        (field for field in fields if isinstance(field, dict) and field.get("id") == "password"),
        None,
    )
    if concealed_field is None:
        concealed_field = {
            "id": "password",
            "type": "CONCEALED",
            "purpose": "PASSWORD",
            "label": "password",
        }
        fields.append(concealed_field)
    concealed_field["value"] = secrets[0][1]
    stored = op_run(
        ["item", "edit", item_id, "--vault", vault],
        payload=json.dumps(document),
    )
else:
    document = {
        "title": item,
        "category": "PASSWORD",
        "fields": [
            {
                "id": "password",
                "type": "CONCEALED",
                "purpose": "PASSWORD",
                "label": "password",
                "value": secrets[0][1],
            },
            {
                "id": "notesPlain",
                "type": "STRING",
                "purpose": "NOTES",
                "label": "notesPlain",
                "value": "Managed by hermes-agent-template; rotate through the provisioner.",
            },
        ],
    }
    stored = op_run(
        ["item", "create", "--vault", vault, "-"],
        payload=json.dumps(document),
    )

if stored.returncode != 0:
    fail("op rejected the item update")

reference = f"op://{vault}/{item}/password"
verified = op_run(["read", "--", reference])
if verified.returncode != 0 or verified.stdout.rstrip("\n") != secrets[0][1]:
    fail("the stored reference did not resolve to the supplied value")

print(reference)
