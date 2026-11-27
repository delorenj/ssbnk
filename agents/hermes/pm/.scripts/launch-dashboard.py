#!/usr/bin/env python3
"""launch-dashboard: the runbook of everything a launch-mode PM cannot move forward without the owner.

The standard is docs/launch-dashboard.md in the hermes-agent template; this script is its driver and
launch-pass.py calls it on every --apply. Inert unless the repo's `.launch.yaml` says `mode: launch`.

  launch-dashboard.py --check                      validate the data file and the catalog (exit 1 on a problem)
  launch-dashboard.py --ops FILE                   apply ops, re-render, publish (ops: a JSON list, or an object with `dashboard`)
  launch-dashboard.py --render [--out DIR] [--data FILE]
                                                   render index.html + dashboard.json, touch nothing else
  launch-dashboard.py --publish                    render from runtime/launch-dashboard.json and publish
  launch-dashboard.py --brief                      the compact section the launch pass hands the PM

Data: <role>/runtime/launch-dashboard.json (schema launch-dashboard/1), written only through ops.
Catalog: <role>/.scripts/lib/launch-marketplaces.json (schema launch-marketplaces/1), a template asset.
Ops: upsert, check, uncheck, remove, requirement, marketplaces.

stdlib only, python3. Env: LAUNCH_DASHBOARD_PUBLISHER (the publish.py to run, tests),
LAUNCH_PLANE_BASE (default https://plane.delo.sh).
"""
from __future__ import annotations

import fcntl
import html
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

HERE = Path(__file__).resolve().parent


def _load_launch_pass():
    mod = sys.modules.get("launch_pass")
    if mod is not None:
        return mod
    spec = importlib.util.spec_from_file_location("launch_pass", HERE / "launch-pass.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["launch_pass"] = mod
    spec.loader.exec_module(mod)
    return mod


LP = _load_launch_pass()
ROLE_DIR = LP.ROLE_DIR
RT = LP.RT
DATA_FILE = RT / "launch-dashboard.json"
LOCK_FILE = RT / "launch-dashboard.lock"
SITE_DIR = RT / "launch-dashboard-site"
CARDS_FILE = RT / "launch-dashboard-cards.json"
CARD_TTL = 1800  # seconds a cached ticket card is trusted while its lane group is unchanged
READ_BUDGET = 90  # seconds of ticket reads per render; the rest come from the cache and the page says so
CATALOG_FILE = HERE / "lib" / "launch-marketplaces.json"
PUBLISHER = Path(os.environ.get("LAUNCH_DASHBOARD_PUBLISHER") or Path.home() / ".agents" / "skills" / "artifacts" / "scripts" / "publish.py")
PLANE_BASE = (os.environ.get("LAUNCH_PLANE_BASE") or "https://plane.delo.sh").rstrip("/")

SCHEMA = "launch-dashboard/1"
CATALOG_SCHEMA = "launch-marketplaces/1"
KINDS = ("account", "console", "legal", "money", "credential", "device", "decision", "reply", "publish")
STEPPED_KINDS = ("account", "console", "legal", "money", "credential", "publish")  # steps >= 2, a full URL first
DEFAULT_KINDS = ("decision", "reply", "device")  # the PM can act on silence only here; the rest need Jarad's own hands
ITEM_FIELDS = ("id", "order", "title", "why", "kind", "marketplace", "steps", "reply", "done_when", "recommend",
               "default", "refs", "artifacts", "after", "covers", "status", "evidence", "verified_at")
REQ_STATUSES = ("met", "agent", "owner", "na")
OP_NAMES = ("upsert", "check", "uncheck", "remove", "requirement", "marketplaces")
MAX_OPS = 40
# "Waiting on you" means the owner: needs-input or human. lifecycle:blocked alone is usually another ticket or scope.
WAIT_LABELS = ("lifecycle:needs-input", "lifecycle:human")
GAP_RANK = ("waiting", "unreadable", "publish", "item", "board", "marketplace", "catalog")
BANNER_SHOWN = 6
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
REQ_ID_RE = re.compile(r"^[a-z]{2}\.[a-z0-9][a-z0-9.-]*$")
REF_ANY = re.compile(r"\b([A-Z][A-Z0-9]*)-(\d+)\b")
URL_ANY = re.compile(r"https?://[^\s<>\"']+")
FIRST_STEP_URL = re.compile(r"https://[^\s<>\"']+")
BAD_LOCAL = re.compile(
    r"file://|\bs3://|(?<![\w/.:])/(?:home|tmp|Users|var|etc|root|mnt|opt)/\S+"
    r"|(?<![\w/.~])~/\S+"  # a home-relative path
    r"|(?<![\w/.:@-])(?:projects/[\w.-]+/\d{4}-\d\d-\d\d|builds|share)/[\w.-]+\S*")  # a bucket key
# The verb must govern the build itself: "Verify your identity ..., then upload the build" is a normal Play step.
BAD_WORDS = re.compile(
    r"\b(?:verify|sign[- ]?off(?: on)?|play[- ]?test|try out|qa)\s+(?:on\s+)?(?:that\s+)?(?:the|this|that|a|our)\s+(?:(?:new|latest|current|final|release|play|ios|android)\s+){0,2}(?:build|apk|ipa|candidate|gate)s?\b"
    r"|\btest (?:out )?(?:the |this |that |a |our )?(?:new |latest |current )?(?:build|apk|ipa|candidate)s?\b"
    r"|\bapprove (?:the |this |that )?(?:build|candidate|gate|ticket)s?\b", re.I)
NOT_IMPERATIVE = ("the", "a", "an", "this", "that", "pending", "waiting", "need", "needs", "todo", "task", "step", "we", "i", "it")
HOLLOW_EVIDENCE = re.compile(
    r"^\s*(?:(?:jarad|the owner|owner|he|user)\b.{0,40}\b(?:said|says|replied|reply|confirmed|told|messaged)\b|(?:done|ok|okay|yes|replied|confirmed)\W*$)", re.I)


# ------------------------------------------------------------------------------------- small helpers

def now() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def et(dt: datetime) -> str:
    return dt.astimezone(LP.et_zone()).strftime("%Y-%m-%d %H:%M %Z")


def esc(s) -> str:
    return html.escape(str(s if s is not None else ""), quote=True)


def is_str(v) -> bool:
    return isinstance(v, str) and bool(v.strip())


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def write_json(path: Path, body) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(body, indent=2, ensure_ascii=False) + "\n")
    tmp.replace(path)


def empty_data() -> dict:
    return {"schema": SCHEMA, "marketplaces": [], "items": [], "requirements": {}, "published": {}}


def load_data(path: Path) -> dict:
    data = read_json(path, None)
    if not isinstance(data, dict):
        return empty_data()
    out = empty_data()
    out.update({k: v for k, v in data.items() if k in out or k == "verified_at"})
    if not isinstance(out["items"], list):
        out["items"] = []
    if not isinstance(out["requirements"], dict):
        out["requirements"] = {}
    if not isinstance(out["marketplaces"], list):
        out["marketplaces"] = []
    return out


def load_catalog() -> dict:
    cat = read_json(CATALOG_FILE, None)
    if not isinstance(cat, dict) or cat.get("schema") != CATALOG_SCHEMA or not isinstance(cat.get("requirements"), list):
        return {"schema": CATALOG_SCHEMA, "marketplaces": {}, "requirements": [], "error": f"{CATALOG_FILE} is missing or not {CATALOG_SCHEMA}"}
    cat.setdefault("marketplaces", {})
    return cat


def project_info(repo: Path) -> dict:
    proj = LP.project(repo)
    tp = proj.get("ticket_provider") or {}
    return {
        "name": proj.get("project_name") or repo.name,
        "id": str(proj.get("project_id") or repo.name).lower(),
        "workspace": tp.get("workspace") or "",
        "identifier": tp.get("identifier") or "",
    }


def bot_username() -> str:
    text = LP._read(ROLE_DIR / "role.yaml")
    m = re.search(r"^telegram:\s*\n((?:[ \t]+.*\n?|\n)*)", text, re.M)
    block = m.group(1) if m else ""
    b = re.search(r"^\s+bot_username:\s*\"?([A-Za-z0-9_]+)\"?", block, re.M)
    return b.group(1) if b else ""


def ticket_prefixes(repo: Path, decl: dict) -> set[str]:
    out = set()
    for d in LP.board_dirs(repo, decl):
        ident = ((LP.project(d).get("ticket_provider") or {}).get("identifier") or "").strip()
        if ident:
            out.add(ident)
    return out


# ----------------------------------------------------------------------------------------- items

def text_fields(it: dict) -> list[str]:
    out = [str(it.get(k) or "") for k in ("title", "why", "reply", "done_when", "recommend", "default", "evidence")]
    out += [str(s) for s in (it.get("steps") or []) if isinstance(s, str)]
    return out


def refs_in_item(it: dict, prefixes: set[str]) -> set[str]:
    found = {r for r in (it.get("refs") or []) if isinstance(r, str)}
    for t in text_fields(it):
        for m in REF_ANY.finditer(t):
            if not prefixes or m.group(1) in prefixes:
                found.add(m.group(0))
    return found


def item_problems(it, ctx: dict) -> list[str]:
    """Every rule the standard sets for one item, as human-readable reasons; empty when the item holds up."""
    if not isinstance(it, dict):
        return ["item must be an object"]
    out: list[str] = []
    unknown = sorted(set(it) - set(ITEM_FIELDS))
    if unknown:
        out.append(f"unknown field(s) {', '.join(unknown)}")
    iid = it.get("id")
    if not (isinstance(iid, str) and ID_RE.match(iid)):
        out.append("`id` must be a lowercase slug (a-z, 0-9, dashes)")
    order = it.get("order")
    if isinstance(order, bool) or not isinstance(order, (int, float)):
        out.append("`order` must be a number")
    for key in ("title", "why", "done_when", "recommend"):
        if not is_str(it.get(key)):
            out.append(f"`{key}` is required" + (" (rule 3: the step says when it is done)" if key == "done_when" else ""))
    kind = it.get("kind")
    if kind not in KINDS:
        out.append(f"`kind` must be one of {', '.join(KINDS)}")
    title = it.get("title") if is_str(it.get("title")) else ""
    first = (title.split() or [""])[0].lower().strip(".,:;")
    if title and (first in NOT_IMPERATIVE or title.rstrip().endswith("?") or re.match(r"^[A-Z][A-Z0-9]*-\d+\b", title)):
        out.append("`title` must be an imperative action (rule 3), not a noun phrase or a question")
    steps = it.get("steps")
    if not (isinstance(steps, list) and steps and all(is_str(s) for s in steps)):
        out.append("`steps` must be a non-empty list of strings (rule 3)")
    elif kind in STEPPED_KINDS:
        if len(steps) < 2:
            out.append(f"a `{kind}` item needs at least two concrete steps (rule 6)")
        if not FIRST_STEP_URL.search(steps[0]):
            out.append(f"the first step of a `{kind}` item must name where to go with a full https URL (rule 6)")
    if kind != "publish" and not is_str(it.get("reply")):
        out.append("`reply` (the exact words Jarad sends back) is required (rule 3)")
    elif it.get("reply") is not None and not isinstance(it.get("reply"), str):
        out.append("`reply` must be a string")
    default = it.get("default")
    if default is not None and not is_str(default):
        out.append("`default` must be null or a sentence")
    elif is_str(default) and kind not in DEFAULT_KINDS:
        out.append(f"a `{kind}` step has no default: only a reversible step the PM can take on silence (kinds {', '.join(DEFAULT_KINDS)}) may carry one")
    mp = it.get("marketplace")
    if mp is not None and mp not in ctx["marketplaces"]:
        out.append(f"`marketplace` must be null or one of {', '.join(sorted(ctx['marketplaces'])) or '(none in the catalog)'}")
    if kind == "publish" and mp is None:
        out.append("a `publish` item must name its `marketplace`")
    refs = it.get("refs", [])
    if not (isinstance(refs, list) and all(isinstance(r, str) and LP.REF.match(r) for r in refs)):
        out.append("`refs` must be a list of ticket refs like ABC-123")
    else:
        bad = [r for r in refs if ctx["prefixes"] and r.split("-")[0] not in ctx["prefixes"]]
        if bad:
            out.append(f"`refs` {', '.join(bad)} are not on this board ({', '.join(sorted(ctx['prefixes']))})")
    arts = it.get("artifacts", [])
    if not isinstance(arts, list):
        out.append("`artifacts` must be a list of {label, url}")
    else:
        for a in arts:
            url = a.get("url") if isinstance(a, dict) else None
            if not (isinstance(a, dict) and is_str(a.get("label")) and isinstance(url, str) and url.startswith("https://") and " " not in url):
                out.append(f"artifact {json.dumps(a)[:80]} must be {{label, url}} with an https URL (rule 5): a file://, a local path or a bucket key is refused")
    for key in ("after", "covers"):
        v = it.get(key, [])
        if not (isinstance(v, list) and all(isinstance(x, str) for x in v)):
            out.append(f"`{key}` must be a list of strings")
    if isinstance(it.get("after"), list) and iid in it["after"]:
        out.append("an item cannot come after itself")
    for cov in it.get("covers") or []:
        if isinstance(cov, str) and ctx["catalog_ids"] and cov not in ctx["catalog_ids"]:
            out.append(f"`covers` {cov!r} is not a catalog requirement")
    status = it.get("status", "open")
    if status not in ("open", "done"):
        out.append("`status` must be open or done")
    if status == "done" and not is_str(it.get("evidence")):
        out.append("a done item needs `evidence` (a link or a one-line read-back)")
    blob = "\n".join(text_fields(it))
    m = BAD_LOCAL.search(blob)
    if m:
        out.append(f"text points at a local path or file:// ({m.group(0)[:40]}): publish it and link the https URL (rule 5)")
    for key in ("title", "reply", "recommend"):
        if isinstance(it.get(key), str) and BAD_WORDS.search(it[key]):
            out.append(f"`{key}` asks Jarad to verify, test or sign off a build: his play is the gate, never a step")
    steps_blob = "\n".join(s for s in steps if isinstance(s, str)) if isinstance(steps, list) else ""
    if BAD_WORDS.search(steps_blob):
        out.append("a step asks Jarad to verify, test or sign off a build: his play is the gate, never a step")
    return out


def item_ctx(data: dict, catalog: dict, prefixes: set[str]) -> dict:
    return {
        "marketplaces": set((catalog.get("marketplaces") or {}).keys()) | {r.get("marketplace") for r in catalog["requirements"] if r.get("marketplace")},
        "catalog_ids": {r["id"] for r in catalog["requirements"] if isinstance(r, dict) and "id" in r},
        "prefixes": prefixes,
    }


def order_items(items: list[dict]) -> list[dict]:
    """One numbered sequence: by `order`, but never before an item it comes `after`. Stable, cycle-safe."""
    by_id = {i["id"]: i for i in items if isinstance(i, dict) and "id" in i}
    key = lambda i: (float(i.get("order") or 0) if isinstance(i.get("order"), (int, float)) else 0.0, str(i.get("id")))
    placed: list[dict] = []
    done: set[str] = set()
    left = sorted(by_id.values(), key=key)
    while left:
        for i in left:
            if all(a in done or a not in by_id for a in (i.get("after") or [])):
                placed.append(i)
                done.add(i["id"])
                left.remove(i)
                break
        else:  # a cycle: keep the order, validation names it
            placed.extend(left)
            break
    return placed


def cycle_problems(items: list[dict]) -> dict[str, str]:
    by_id = {i["id"]: i for i in items if isinstance(i, dict) and isinstance(i.get("id"), str)}
    bad: dict[str, str] = {}
    for start in by_id:
        seen, stack = set(), list(by_id[start].get("after") or [])
        while stack:
            cur = stack.pop()
            if cur == start:
                bad[start] = "its `after` chain loops back to itself"
                break
            if cur in seen or cur not in by_id:
                continue
            seen.add(cur)
            stack.extend(by_id[cur].get("after") or [])
    return bad


def broken_items(data: dict, ctx: dict) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    items = [i for i in data["items"] if isinstance(i, dict)]
    ids = {i.get("id") for i in items}
    seen: set = set()
    cycles = cycle_problems(items)
    for n, it in enumerate(data["items"]):
        name = it.get("id") if isinstance(it, dict) and isinstance(it.get("id"), str) else f"#{n + 1}"
        probs = item_problems(it, ctx)
        if isinstance(it, dict):
            if it.get("id") in seen:
                probs.append("duplicate `id`")
            seen.add(it.get("id"))
            for a in it.get("after") or []:
                if a not in ids:
                    probs.append(f"`after` {a!r} is not an item")
            if name in cycles:
                probs.append(cycles[name])
        if probs:
            out[name] = probs
    return out


def requirement_problem(entry, ids: set[str]) -> str:
    """Why a requirements entry does not hold up (rule 7), or ""."""
    if not isinstance(entry, dict):
        return "entry must be an object"
    st = entry.get("status")
    if st not in REQ_STATUSES:
        return f"status must be one of {', '.join(REQ_STATUSES)}"
    if st == "met" and not is_str(entry.get("evidence")):
        return "met with no evidence"
    if st == "met" and (len(entry["evidence"].strip()) < 8 or HOLLOW_EVIDENCE.match(entry["evidence"])):
        return "met with hollow evidence (cite a URL, a ticket or a one-line read-back; Jarad's reply is never evidence)"
    if st == "agent" and not (isinstance(entry.get("ref"), str) and LP.REF.match(entry["ref"])):
        return "agent with no ticket ref"
    if st == "owner" and not is_str(entry.get("item")):
        return "owner with no item"
    if st == "owner" and entry["item"] not in ids:
        return f"owner item {entry['item']!r} does not exist"
    if st == "na" and not is_str(entry.get("why")):
        return "n/a with no reason"
    if st == "na" and len(entry["why"].strip()) < 8:
        return "n/a with a hollow reason (say why the requirement does not apply)"
    return ""


# ------------------------------------------------------------------------------------------- ops

def apply_ops(data: dict, ops, catalog: dict, prefixes: set[str]) -> list[dict]:
    """Apply the plan's dashboard ops to `data` in place, one receipt entry per op. A refusal says why and changes nothing."""
    entries: list[dict] = []
    ctx = item_ctx(data, catalog, prefixes)
    cat_ids = ctx["catalog_ids"]
    stamp = iso(now())
    if not isinstance(ops, list):
        return [{"op": "dashboard", "ref": "ops", "status": "refused", "detail": "`dashboard` must be a list of ops"}]
    if len(ops) > MAX_OPS:
        entries.append({"op": "dashboard", "ref": "cap", "status": "refused", "detail": f"{len(ops)} ops sent, applying the first {MAX_OPS}"})
        ops = ops[:MAX_OPS]

    def out(name: str, ref: str, ok: bool, detail: str) -> None:
        entries.append({"op": "dashboard", "ref": f"{name} {ref}".strip(), "status": "ok" if ok else "refused", "detail": detail})

    def find(iid):
        return next((i for i in data["items"] if isinstance(i, dict) and i.get("id") == iid), None)

    for raw in ops:
        if not isinstance(raw, dict) or raw.get("op") not in OP_NAMES:
            out("?", "", False, f"op must be an object whose `op` is one of {', '.join(OP_NAMES)}")
            continue
        name = raw["op"]
        if name == "upsert":
            item = raw.get("item")
            iid = item.get("id", "") if isinstance(item, dict) else ""
            if not isinstance(item, dict):
                out(name, "", False, "`item` must be an object")
                continue
            old = find(iid)
            cand = {k: v for k, v in item.items()}
            for k, v in (("refs", []), ("artifacts", []), ("after", []), ("covers", []), ("marketplace", None), ("default", None)):
                cand.setdefault(k, v)
            if cand.get("status") == "done":
                out(name, iid, False, "a new or replaced item starts open: finish it with a `check` op and evidence")
                continue
            cand["status"] = (old or {}).get("status", "open")
            cand["evidence"] = (old or {}).get("evidence")
            cand["verified_at"] = (old or {}).get("verified_at")
            if cand["status"] == "open":
                cand["evidence"] = cand["verified_at"] = None
            probs = item_problems({k: v for k, v in cand.items() if not (k in ("evidence", "verified_at") and v is None)}, ctx)
            probs += [f"`after` {a!r} is not an item" for a in cand.get("after") or [] if isinstance(a, str) and a != iid and find(a) is None]
            if probs:
                out(name, iid, False, "; ".join(probs))
                continue
            trial = [i for i in data["items"] if not (isinstance(i, dict) and i.get("id") == iid)] + [cand]
            loop = cycle_problems(trial).get(iid)
            if loop:
                out(name, iid, False, loop)
                continue
            if old is None:
                data["items"].append(cand)
            else:
                data["items"][data["items"].index(old)] = cand
            out(name, iid, True, "replaced" if old else "added")
        elif name in ("check", "uncheck", "remove"):
            iid = raw.get("id")
            it = find(iid) if isinstance(iid, str) else None
            if it is None:
                out(name, str(iid or ""), False, "no such item")
            elif name == "check":
                ev = raw.get("evidence")
                if not is_str(ev) or len(ev.strip()) < 8:
                    out(name, iid, False, "needs `evidence`: a link or a one-line read-back of what you checked")
                elif HOLLOW_EVIDENCE.match(ev):
                    out(name, iid, False, "Jarad's reply is a hint to check, never the evidence: read `done_when` and cite what you read")
                elif "\n" in ev.strip():
                    out(name, iid, False, "evidence is one line")
                else:
                    it.update(status="done", evidence=ev.strip(), verified_at=stamp)
                    out(name, iid, True, "checked")
            elif name == "uncheck":
                if not is_str(raw.get("why")):
                    out(name, iid, False, "needs `why`")
                else:
                    it.update(status="open", evidence=None, verified_at=None)
                    out(name, iid, True, f"reopened: {raw['why'].strip()[:120]}")
            else:
                dependents = [i["id"] for i in data["items"] if isinstance(i, dict) and iid in (i.get("after") or [])]
                if not is_str(raw.get("why")):
                    out(name, iid, False, "needs `why`")
                elif dependents:
                    out(name, iid, False, f"{', '.join(dependents)} come(s) after it: change those first")
                else:
                    data["items"].remove(it)
                    out(name, iid, True, f"removed: {raw['why'].strip()[:120]}")
        elif name == "requirement":
            rid = raw.get("id")
            if not (isinstance(rid, str) and rid in cat_ids):
                out(name, str(rid or ""), False, "not a catalog requirement id")
                continue
            entry = {k: raw[k] for k in ("status", "evidence", "ref", "item", "why") if k in raw}
            probs = requirement_problem(entry, {i.get("id") for i in data["items"] if isinstance(i, dict)})
            if probs:
                out(name, rid, False, probs + (" (add the item first)" if "does not exist" in probs else ""))
            elif entry.get("status") == "agent" and prefixes and entry["ref"].split("-")[0] not in prefixes:
                out(name, rid, False, f"{entry['ref']} is not on this board")
            else:
                data["requirements"][rid] = entry
                out(name, rid, True, entry["status"])
        else:  # marketplaces
            value = raw.get("value")
            known = ctx["marketplaces"]
            if not (isinstance(value, list) and value and all(isinstance(v, str) and v in known for v in value)):
                out(name, "", False, f"`value` must be a non-empty list drawn from {', '.join(sorted(known))}")
            else:
                data["marketplaces"] = list(dict.fromkeys(value))
                out(name, "", True, ", ".join(data["marketplaces"]))
    return entries


# --------------------------------------------------------------------------------------- tickets

def strip_md(s: str) -> str:
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"[`*_>#]+", "", s)
    return re.sub(r"\s+", " ", s).strip()


def gist(raw: dict) -> str:
    """One line for the hover card: the Goal paragraph, else the description's first sentence."""
    text = raw.get("description_text") or ""
    if not text.strip():
        text = re.sub(r"<(?:/p|/h\d|/li|br\s*/?)>", "\n\n", raw.get("description_html") or "")
        text = html.unescape(re.sub(r"<[^>]+>", "", text))
    text = text.strip()
    m = re.search(r"(?im)^\s*(?:#{1,4}\s*)?goal\s*:?\s*\n+\s*(.+?)(?:\n\s*\n|\n#|\Z)", text, re.S) \
        or re.search(r"(?im)^\s*goal\s*:\s*(.+?)(?:\n\s*\n|\Z)", text, re.S)
    para = strip_md(m.group(1)) if m else ""
    if not para and text:
        body = "\n".join(l for l in text.splitlines() if not re.match(r"^\s*(?:#{1,6}\s*)?(?:outcome|goal|summary|overview|description|context|background)\s*:?\s*$", l, re.I))
        flat = strip_md(body)
        para = re.split(r"(?<=[.!?])\s", flat, maxsplit=1)[0]
    return para[:180].rstrip() + ("..." if len(para) > 180 else "")


def plane_url(info: dict, ref: str) -> str:
    return f"{PLANE_BASE}/{info['workspace']}/browse/{ref}/" if info["workspace"] else ""


def owner_waiting(labels, group: str) -> bool:
    """Waiting on the owner: a needs-input or human label on a ticket that is still open. A closed ticket never waits."""
    return group in LP.OPEN and any(l in WAIT_LABELS for l in (labels or []))


def info_from_raw(ref: str, t: dict, proj: dict) -> dict:
    labels = [str(l) for l in (t.get("label_names") or [])]
    return {
        "ref": ref, "title": t.get("name") or "", "lane": t.get("state_name") or "?", "group": t.get("state_group") or "",
        "pri": (t.get("priority") or "none").lower(), "labels": labels,
        "url": t.get("url") or plane_url(proj, ref), "gist": gist(t),
        "waiting": owner_waiting(labels, t.get("state_group") or ""),
        "bug": any(l in ("bug", "kind:bug") for l in labels),
        "origin": "agent" if (t.get("external_id") or t.get("external_source")) else "owner",
    }


def info_from_row(row: dict, proj: dict) -> dict:
    labels = list(row["labels"])
    return {
        "ref": row["ref"], "title": row["name"], "lane": row["lane"], "group": row["group"], "pri": row["pri"], "labels": labels,
        "url": plane_url(proj, row["ref"]), "gist": "", "waiting": owner_waiting(labels, row["group"]),
        "bug": row["bug"], "origin": row["origin"],
    }


class Board:
    """What the dashboard knows about the tickets: every ref's lane (any state) plus detail for open and referenced ones."""

    def __init__(self):
        self.ok = False
        self.error = ""
        self.groups: dict[str, str] = {}
        self.tickets: dict[str, dict] = {}
        self.prefixes: set[str] = set()
        self.stale_cards: list[str] = []  # refs shown from an old cache entry because the read budget ran out or a read failed
        self.unreadable: list[str] = []  # refs with no card at all: the read failed or ran out of budget and no cache entry existed
        self.failed_reads: list[str] = []  # refs whose read failed after every retry
        self.skipped_reads: list[str] = []  # refs not read because the budget ran out
        self.off_list: set[str] = set()  # refs read on request that the board listing does not carry (outside the epic or cut line)
        self.dirs: list[Path] = []

    def known(self, ref: str) -> bool:
        """The ref resolves on a driven board: listed, or fetched by its ref."""
        return ref in self.groups or ref in self.off_list

    def group(self, ref: str) -> str:
        return self.groups.get(ref) or (self.tickets.get(ref) or {}).get("group", "")

    def open_tickets(self) -> list[dict]:
        return sorted((t for t in self.tickets.values() if t["group"] in LP.OPEN and t["ref"] in self.groups), key=lambda t: int(t["ref"].rsplit("-", 1)[1]))


def gather(repo: Path, decl: dict, proj: dict, wanted: set[str], rows: list[dict] | None = None,
           cache_file: Path | None = None, budget: float = READ_BUDGET) -> Board:
    """Read the board once. With `rows` (the launch pass's own board read) only closed referenced tickets cost a read.
    Without rows, a card read inside CARD_TTL with the same lane group is reused, and reading stops after `budget` seconds:
    the rest come from the cache (marked stale) so a render never outlives the pass's tool call."""
    b = Board()
    try:
        _, where, groups = LP.ref_dirs(repo, decl)
    except Exception as e:
        b.error = f"{type(e).__name__}: {e}"[:160]
        return b
    b.groups = groups
    b.prefixes = {r.split("-")[0] for r in groups}
    b.ok = True
    b.dirs = LP.board_dirs(repo, decl)
    # A ref on a driven board that the listing does not carry (outside the launch epic or cut line) still gets a card.
    unlisted = sorted(r for r in wanted if r not in groups and r.split("-")[0] in b.prefixes)
    if rows is not None:
        for r in rows:
            b.tickets[r["ref"]] = info_from_row(r, proj)
        todo = [r for r in wanted if r in groups and r not in b.tickets and groups[r] not in LP.OPEN]
        detail_refs: list[str] = []
    else:
        todo = []
        detail_refs = sorted({r for r, g in groups.items() if g in LP.OPEN} | {r for r in wanted if r in groups})
    cache = read_json(cache_file, {}) if (cache_file is not None and rows is None) else {}
    if not isinstance(cache, dict):
        cache = {}
    deadline = time.monotonic() + budget
    stamp_now = now()

    def fresh(ref):
        e = cache.get(ref)
        if not (isinstance(e, dict) and isinstance(e.get("info"), dict) and (ref not in groups or e.get("group") == groups.get(ref))):
            return None
        try:
            age = (stamp_now - datetime.strptime(e["at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)).total_seconds()
        except (KeyError, ValueError, TypeError):
            return None
        return reflag(e["info"]) if 0 <= age < CARD_TTL else None

    def reflag(info):
        """A cached card is re-judged by today's rule for waiting, so an old entry never keeps a stale chip."""
        return {**info, "waiting": owner_waiting(info.get("labels"), info.get("group", ""))}

    def read(ref):
        hit = fresh(ref)
        if hit is not None:
            return ref, hit, "cache"
        listed = ref in groups
        for attempt in range(4 if listed else 2):
            if time.monotonic() > deadline:
                return ref, None, "budget"
            # Any scope can read any ref; try each driven scope so a ref outside the listing still resolves.
            for d in ([repo] if listed else b.dirs):
                try:
                    return ref, LP.px_json(d, "task", "get", ref)["ticket"], "read"
                except Exception:
                    pass
            if attempt == (3 if listed else 1):
                return ref, None, "failed"
            time.sleep(1 + 2 * attempt)
    with ThreadPoolExecutor(8) as pool:
        for ref, raw, how in pool.map(read, detail_refs + todo + unlisted):
            if how == "cache":
                b.tickets[ref] = raw
            elif raw is not None:
                b.tickets[ref] = info_from_raw(ref, raw, proj)
                if cache_file is not None and rows is None:
                    cache[ref] = {"at": iso(stamp_now), "group": groups.get(ref, ""), "info": b.tickets[ref]}
            else:
                if how == "failed":
                    b.failed_reads.append(ref)
                else:
                    b.skipped_reads.append(ref)
                old = cache.get(ref)
                if isinstance(old, dict) and isinstance(old.get("info"), dict):
                    b.tickets[ref] = {**reflag(old["info"]), "group": groups.get(ref, old["info"].get("group", ""))}
                    b.stale_cards.append(ref)
                elif ref in groups:
                    b.tickets[ref] = {"ref": ref, "title": "(unreadable)", "lane": "?", "group": groups[ref], "pri": "none", "labels": [],
                                      "url": plane_url(proj, ref), "gist": "", "waiting": False, "bug": False, "origin": "owner", "unreadable": True}
                    b.stale_cards.append(ref)
                    b.unreadable.append(ref)
            if ref in b.tickets and ref not in groups:
                b.off_list.add(ref)
    if cache_file is not None and rows is None:
        try:
            write_json(cache_file, {r: e for r, e in cache.items() if r in groups or r in b.off_list})
        except OSError:
            pass
    return b


def launch_critical(decl: dict, board: Board) -> set[str]:
    """The declaration's cut-line hint, plus Todo: the charter says Todo holds only launch-critical work."""
    return set(decl.get("launch_critical") or []) | {t["ref"] for t in board.open_tickets() if t["lane"] == "Todo"}


# ------------------------------------------------------------------------------------- repo paths

def https_base(remote: str) -> str:
    remote = remote.strip()
    m = re.match(r"^(?:git@|ssh://git@|https://(?:[^@/]+@)?)(github\.com)[:/](.+?)(?:\.git)?/?$", remote)
    return f"https://{m.group(1)}/{m.group(2)}" if m else ""


class RepoIndex:
    """Which paths a text can link: `git ls-files` of the repo and of each child scope that is its own repo."""

    def __init__(self, repo: Path, decl: dict):
        self.roots: list[tuple[str, set[str], str]] = []
        self._add(repo, "")
        for name, d in LP.scope_dirs(repo, decl).items():
            top = self._git(d, "rev-parse", "--show-toplevel")
            if top and Path(top).resolve() == d.resolve():
                self._add(d, name.rstrip("/") + "/")

    @staticmethod
    def _git(d: Path, *args: str) -> str:
        try:
            r = subprocess.run(["git", "-C", str(d), *args], capture_output=True, text=True, timeout=30)
            return r.stdout.strip() if r.returncode == 0 else ""
        except Exception:
            return ""

    def _add(self, d: Path, prefix: str) -> None:
        listing = self._git(d, "ls-files", "-z")
        base = https_base(self._git(d, "remote", "get-url", "origin"))
        files = {f for f in listing.split("\0") if f}
        if base and files:
            self.roots.append((prefix, files, base))

    def url(self, path: str) -> str:
        path = path[2:] if path.startswith("./") else path
        for prefix, files, base in self.roots:
            for cand in ([path[len(prefix):]] if prefix and path.startswith(prefix) else []) + [path]:
                if cand in files:
                    return f"{base}/blob/main/{quote(cand)}"
        return ""


# ------------------------------------------------------------------------------------- linkifier

TOKEN = re.compile(
    r"(?P<url>https?://[^\s<>\"']+)"
    r"|(?P<ref>\b[A-Z][A-Z0-9]*-\d+\b)"
    r"|(?P<path>(?<![\w/@:.+-])(?:\./)?[\w.][\w.+-]*(?:/[\w.+-]+)+/?|(?<![\w/@:.+-])[\w][\w+-]*\.[A-Za-z][A-Za-z0-9]{0,7}\b)")


CODE_SPAN = re.compile(r"`([^`\n]+)`")


def inline(s, plain=esc) -> str:
    """Escape `s`; text in backticks becomes <code> (escaped), the rest goes through `plain`."""
    s = str(s if s is not None else "")
    out, pos = [], 0
    for m in CODE_SPAN.finditer(s):
        out.append(plain(s[pos:m.start()]))
        out.append(f"<code>{esc(m.group(1))}</code>")
        pos = m.end()
    out.append(plain(s[pos:]))
    return "".join(out)


def trim_url(tok: str) -> str:
    """A bare URL minus trailing punctuation; a closing paren stays when the URL opened one (wiki-style links)."""
    while tok:
        if tok[-1] in ".,;:!?" or (tok[-1] == ")" and tok.count(")") > tok.count("(")):
            tok = tok[:-1]
        else:
            break
    return tok


class Linker:
    def __init__(self, board: Board, repoidx: RepoIndex, prefixes: set[str], proj: dict):
        self.board, self.repoidx, self.prefixes, self.proj = board, repoidx, prefixes, proj
        self.used: set[str] = set()

    def chip(self, ref: str) -> str:
        t = self.board.tickets.get(ref)
        url = (t or {}).get("url") or plane_url(self.proj, ref)
        self.used.add(ref)
        flag = " wait" if t and t.get("waiting") else ""
        inner = f'<a class="tk{flag}" href="{esc(url)}" data-ref="{esc(ref)}" target="_blank" rel="noopener">{esc(ref)}</a>' if url else f'<span class="tk" data-ref="{esc(ref)}">{esc(ref)}</span>'
        return inner

    def text(self, s) -> str:
        return inline(s, self.linked)

    def linked(self, s: str) -> str:
        out, pos = [], 0
        for m in TOKEN.finditer(s):
            out.append(esc(s[pos:m.start()]))
            pos = m.end()
            tok = m.group(0)
            if m.group("url"):
                core = trim_url(tok)
                out.append(f'<a href="{esc(core)}" target="_blank" rel="noopener">{esc(core)}</a>' + esc(tok[len(core):]))
            elif m.group("ref"):
                prefix = tok.split("-")[0]
                out.append(self.chip(tok) if (prefix in self.prefixes or prefix in self.board.prefixes) else esc(tok))
            else:
                core = tok.rstrip(".,;:")
                link = self.repoidx.url(core)
                out.append(f'<a class="path" href="{esc(link)}" target="_blank" rel="noopener">{esc(core)}</a>' + esc(tok[len(core):]) if link else esc(tok))
        out.append(esc(s[pos:]))
        return "".join(out)


# ----------------------------------------------------------------------------- the model + gaps

def compute_gaps(data: dict, catalog: dict, board: Board, decl: dict, broken: dict[str, list[str]], prefixes: set[str]) -> list[dict]:
    gaps: list[dict] = []
    items = [i for i in data["items"] if isinstance(i, dict)]
    ids = {i.get("id") for i in items}
    if not data["marketplaces"]:
        gaps.append({"kind": "marketplace", "id": "", "text": "No marketplace is declared: set one with a `marketplaces` op so the catalog applies."})
    if not board.ok:
        gaps.append({"kind": "board", "id": "", "text": f"The board could not be read ({board.error or 'px unavailable'}): ticket checks are not done, so completeness is unproven."})
    for req in catalog["requirements"]:
        if req.get("marketplace") not in data["marketplaces"]:
            continue
        entry = data["requirements"].get(req["id"])
        label = f"{req['id']}: {req['title']}"
        cond = "" if req.get("applies_when") == "always" else f" (conditional: {req['applies_when']}; record `na` with the reason, or the real status)"
        if entry is None:
            gaps.append({"kind": "catalog", "id": req["id"], "text": f"{label} has no entry{cond}."})
            continue
        why = requirement_problem(entry, ids)
        if not why and entry["status"] == "agent" and board.ok:
            ref = entry["ref"]
            if not board.known(ref):
                why = f"agent ticket {ref} is not on the board"
            elif board.group(ref) == "cancelled":
                why = f"agent ticket {ref} is cancelled"
        if why:
            gaps.append({"kind": "catalog", "id": req["id"], "text": f"{label}: {why}."})
    if board.ok:
        crit = launch_critical(decl, board)
        referenced: set[str] = set()
        for it in items:
            referenced |= refs_in_item(it, prefixes | board.prefixes)
        for t in board.open_tickets():
            if t["ref"] in crit and t["waiting"] and t["ref"] not in referenced:
                gaps.append({"kind": "waiting", "id": t["ref"], "text": f"{t['ref']} is launch-critical and waiting on you ({', '.join(l for l in t['labels'] if l in WAIT_LABELS)}) but no step references it: {t['title']}"})
        if board.unreadable:
            refs = sorted(board.unreadable, key=lambda r: (r.split("-")[0], int(r.rsplit("-", 1)[1])))
            n = len(refs)
            gaps.append({"kind": "unreadable", "id": refs[0], "text": f"{n} ticket{'s' if n != 1 else ''} could not be read: {', '.join(refs)}; the page cannot prove completeness "
                                                                       f"(a ticket waiting on you may be among them). The next apply reads them again."})
    for mp in data["marketplaces"]:
        if not any(i.get("kind") == "publish" and i.get("marketplace") == mp for i in items):
            gaps.append({"kind": "publish", "id": mp, "text": f"{(catalog.get('marketplaces') or {}).get(mp, mp)} has no `publish` item: add the final submit or publish step."})
    for iid, probs in broken.items():
        for p in probs:
            gaps.append({"kind": "item", "id": iid, "text": f"Step {iid} breaks a rule: {p}."})
    # The highest-value gaps first, so the banner never hides them behind a long catalog tail.
    gaps.sort(key=lambda g: GAP_RANK.index(g["kind"]))
    return gaps


def agent_work(decl: dict, board: Board) -> list[dict]:
    if not board.ok:
        return []
    crit = launch_critical(decl, board)
    out = []
    for t in board.open_tickets():
        blocker = LP.launch_blocker({"bug": t["bug"], "origin": t["origin"], "pri": t["pri"]})
        if t["ref"] in crit or blocker:
            out.append({**t, "why": "owner-filed High/Urgent bug" if blocker else "launch-critical"})
    return out


def build_model(repo: Path, decl: dict, data: dict, catalog: dict, board: Board, repoidx: RepoIndex, proj: dict, prefixes: set[str]) -> dict:
    ctx = item_ctx(data, catalog, prefixes)
    broken = broken_items(data, ctx)
    gaps = compute_gaps(data, catalog, board, decl, broken, prefixes)
    ordered = order_items([i for i in data["items"] if isinstance(i, dict) and isinstance(i.get("id"), str)])
    number = {i["id"]: n for n, i in enumerate(ordered, 1)}
    items = [{**i, "number": number[i["id"]], "problems": broken.get(i["id"], [])} for i in ordered]
    rows = []
    for req in catalog["requirements"]:
        if req.get("marketplace") not in data["marketplaces"]:
            continue
        entry = data["requirements"].get(req["id"])
        state, why = "gap", ""
        if entry is not None:
            why = requirement_problem(entry, set(number))
            if not why and entry["status"] == "agent" and board.ok and (not board.known(entry["ref"]) or board.group(entry["ref"]) == "cancelled"):
                why = "ticket is not on the board"
            state = "gap" if why else entry["status"]
        rows.append({"id": req["id"], "marketplace": req["marketplace"], "title": req["title"], "applies_when": req.get("applies_when", "always"),
                     "doc_url": req.get("doc_url", ""), "caveat": req.get("caveat", ""), "state": state, "problem": why,
                     "entry": entry or {}, "step": number.get((entry or {}).get("item"))})
    return {
        "schema": SCHEMA, "product": proj["name"], "finish_line": decl.get("finish_line") or "", "epic": decl.get("epic") or "",
        "declared": decl.get("declared") or "", "marketplaces": data["marketplaces"],
        "marketplace_names": {m: (catalog.get("marketplaces") or {}).get(m, m) for m in data["marketplaces"]},
        "items": items, "requirements": rows, "gaps": gaps, "agent_work": agent_work(decl, board),
        "counts": {"open": sum(1 for i in items if i.get("status") != "done"), "done": sum(1 for i in items if i.get("status") == "done"), "gaps": len(gaps)},
        "complete": not gaps, "catalog_checked": catalog.get("checked", ""),
    }


# ------------------------------------------------------------------------------------------ page

CSS = """
:root{--bg:#f5f6f3;--surface:#fff;--sunk:#edf0eb;--line:#d7dcd3;--fg:#1b2420;--muted:#59655f;--accent:#0e6a5a;--accent-ink:#fff;
--ok:#1b7443;--ok-bg:#e1f1e6;--warn:#8f5700;--warn-bg:#faedd0;--bad:#b0251d;--bad-bg:#fbe3df;--chip:#e6eae3;
--sans:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color-scheme:light}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0f1512;--surface:#161d1a;--sunk:#1c2521;--line:#2a3631;--fg:#e5ebe7;--muted:#94a19a;--accent:#52c6ab;--accent-ink:#06201a;
--ok:#63d08c;--ok-bg:#152f1f;--warn:#e6b45c;--warn-bg:#33270e;--bad:#ff8c83;--bad-bg:#3b1a17;--chip:#222d28;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#0f1512;--surface:#161d1a;--sunk:#1c2521;--line:#2a3631;--fg:#e5ebe7;--muted:#94a19a;--accent:#52c6ab;--accent-ink:#06201a;
--ok:#63d08c;--ok-bg:#152f1f;--warn:#e6b45c;--warn-bg:#33270e;--bad:#ff8c83;--bad-bg:#3b1a17;--chip:#222d28;color-scheme:dark}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 var(--sans)}
.wrap{max-width:940px;margin:0 auto;padding-block:28px 56px;padding-left:max(16px,env(safe-area-inset-left,0px));padding-right:max(16px,env(safe-area-inset-right,0px))}
a{color:var(--accent);text-underline-offset:2px;overflow-wrap:anywhere}
h1,h2,h3,h4{text-wrap:balance;line-height:1.25;margin:0}
h1{font-size:1.7rem;letter-spacing:-.01em}
h2{font-size:1.15rem;margin:36px 0 12px}
h3{font-size:1rem}
.eyebrow{font-size:.72rem;letter-spacing:.09em;text-transform:uppercase;color:var(--muted);font-weight:600}
.lede{margin:8px 0 0;max-width:68ch}
.meta{display:flex;flex-wrap:wrap;gap:6px 18px;margin:16px 0 0;color:var(--muted);font-size:.86rem}
.meta b{color:var(--fg);font-weight:600}
.pills{display:flex;flex-wrap:wrap;gap:6px;margin-top:14px}
.pill{display:inline-block;padding:1px 9px;border-radius:99px;background:var(--chip);font-size:.74rem;font-weight:600;color:var(--muted);white-space:nowrap}
.pill.ok{background:var(--ok-bg);color:var(--ok)}.pill.warn{background:var(--warn-bg);color:var(--warn)}.pill.bad{background:var(--bad-bg);color:var(--bad)}
.stats{display:flex;flex-wrap:wrap;gap:6px 26px;margin:18px 0 0;padding:0;list-style:none}
.stats li{display:flex;align-items:baseline;gap:7px}
.stats b{font:700 1.5rem/1 var(--mono);font-variant-numeric:tabular-nums}
.banner{margin-top:20px;padding:14px 16px;border-radius:8px;border:1px solid}
.banner.bad{background:var(--bad-bg);border-color:var(--bad);color:var(--fg)}
.banner.ok{background:var(--ok-bg);border-color:var(--ok)}
.banner strong{display:block;font-size:1rem;color:var(--bad)}.banner.ok strong{color:var(--ok)}
.banner span.muted{display:block;margin-top:2px;font-size:.86rem}.banner details{margin-top:8px}.banner summary{cursor:pointer;font-weight:600;color:var(--bad)}
.banner ul{margin:8px 0 0;padding-left:1.2rem}.banner li{margin:3px 0}
.reply{margin-top:14px;font-size:.88rem;color:var(--muted)}
.steps{display:flex;flex-direction:column;gap:10px}
details.step{background:var(--surface);border:1px solid var(--line);border-radius:8px}
details.step.done{background:var(--sunk)}
details.step>summary{list-style:none;display:grid;grid-template-columns:3rem 1fr;gap:2px 10px;align-items:start;padding:12px 14px;cursor:pointer}
details.step>summary::-webkit-details-marker{display:none}
.num{font:700 1.45rem/1.15 var(--mono);font-variant-numeric:tabular-nums;color:var(--accent)}
.done .num{color:var(--ok)}
.sum{min-width:0}
.sum .t{font-weight:650;font-size:1rem;overflow-wrap:anywhere}
.done .sum .t{text-decoration:line-through;text-decoration-color:var(--muted);color:var(--muted)}
.sum .tags{display:flex;flex-wrap:wrap;gap:5px;margin-top:5px;align-items:center}
.box{display:inline-block;width:1.05rem;height:1.05rem;border:2px solid var(--muted);border-radius:4px;vertical-align:-3px;margin-right:6px;position:relative}
.done .box{background:var(--ok);border-color:var(--ok)}
.done .box::after{content:"";position:absolute;left:3px;top:0;width:4px;height:8px;border:solid var(--bg);border-width:0 2px 2px 0;transform:rotate(45deg)}
.body{padding:0 14px 16px calc(14px + 3rem + 10px);display:grid;gap:12px}
.f h4{font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin-bottom:3px}
.f p{margin:0;max-width:72ch}
.f ol{margin:0;padding-left:1.25rem;max-width:72ch}.f ol li{margin:3px 0}
.f ul{margin:0;padding-left:1.1rem}
code,.mono{font:.86rem var(--mono);background:var(--sunk);padding:1px 6px;border-radius:4px;overflow-wrap:anywhere}
.copy{font:inherit;font-size:.74rem;margin-left:6px;padding:1px 8px;border:1px solid var(--line);border-radius:6px;background:var(--surface);color:var(--fg);cursor:pointer}
.copy:focus-visible,a:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.tk{font:600 .82rem var(--mono);text-decoration:none;background:var(--chip);color:var(--fg);padding:0 6px;border-radius:4px;white-space:nowrap;border-bottom:1px dotted var(--muted)}
.tk:hover{background:var(--accent);color:var(--accent-ink)}
.tk.wait{background:var(--warn-bg);color:var(--warn)}
#tkcard{position:fixed;z-index:50;max-width:min(340px,calc(100vw - 24px));background:var(--surface);color:var(--fg);border:1px solid var(--line);border-radius:8px;padding:10px 12px;box-shadow:0 6px 24px rgba(0,0,0,.22);font-size:.86rem}
#tkcard b{display:block;font-size:.9rem}#tkcard .m{color:var(--muted);font-size:.78rem;margin-top:2px}#tkcard p{margin:6px 0 0}
#tkcard .w{display:inline-block;margin-top:6px;color:var(--warn);background:var(--warn-bg);padding:0 7px;border-radius:4px;font-weight:600;font-size:.78rem}
#tkcard a{display:inline-block;margin-top:8px;font-weight:600}
.agentwork{background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:12px 14px}.agentwork .f p{margin-bottom:8px}
.agent{margin:0;padding:0;list-style:none;display:grid;gap:4px}.agent li{display:flex;gap:8px;align-items:baseline;flex-wrap:wrap}
.tablewrap{overflow-x:auto;border:1px solid var(--line);border-radius:8px;background:var(--surface)}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--line);vertical-align:top;font-size:.88rem}
th{font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);background:var(--sunk)}
tr:last-child td{border-bottom:0}
td .sub{display:block;color:var(--muted);font-size:.78rem;margin-top:2px}
.muted{color:var(--muted)}
footer{margin-top:44px;padding-top:14px;border-top:1px solid var(--line);color:var(--muted);font-size:.8rem;display:flex;flex-wrap:wrap;gap:4px 18px}
@media (max-width:560px){h1{font-size:1.4rem}details.step>summary{grid-template-columns:1fr;gap:0}.body{padding-left:14px}.num{font-size:1.1rem}
.tablewrap{border:0;background:none;overflow:visible}table,tbody,tr,td{display:block;width:100%}thead{display:none}
tr{background:var(--surface);border:1px solid var(--line);border-radius:8px;margin-bottom:8px;padding:8px 12px;display:flex;flex-direction:column;gap:4px}
td{border:0;padding:0}td:nth-child(2){order:-1}}
@media (prefers-reduced-motion:reduce){*{scroll-behavior:auto!important}}
"""

JS = r"""
(function(){
var data={};try{data=JSON.parse(document.getElementById('tk-data').textContent)}catch(e){}
var card=document.createElement('div');card.id='tkcard';card.hidden=true;document.body.appendChild(card);
var cur=null,timer=null,touch=false;try{touch=matchMedia('(hover: none)').matches}catch(e){}
function el(tag,cls,txt){var n=document.createElement(tag);if(cls)n.className=cls;if(txt!=null)n.textContent=txt;return n}
function rich(tag,txt){var n=el(tag),p=String(txt).split('`'),odd=p.length%2===0;
  p.forEach(function(s,i){if(odd&&i===p.length-1){n.appendChild(document.createTextNode('`'+s));return}if(!s)return;n.appendChild(i%2?el('code',null,s):document.createTextNode(s))});return n}
function show(a){
  var ref=a.getAttribute('data-ref'),t=data[ref];clearTimeout(timer);cur=a;card.textContent='';
  if(!t){card.appendChild(el('b',null,ref));card.appendChild(el('div','m','Not found on this board.'))}
  else{card.appendChild(rich('b',ref+' '+t.title));card.appendChild(el('div','m',t.lane+' · '+t.pri+' priority'));
    if(t.gist)card.appendChild(rich('p',t.gist));
    if(t.waiting)card.appendChild(el('span','w','Waiting on you'));
    if(t.url){var o=el('a',null,'Open ticket');o.href=t.url;o.target='_blank';o.rel='noopener';var d=el('div');d.appendChild(o);card.appendChild(d)}}
  card.hidden=false;
  var r=a.getBoundingClientRect(),w=card.offsetWidth,h=card.offsetHeight;
  var x=Math.max(8,Math.min(r.left,innerWidth-w-8)),y=r.bottom+6;if(y+h>innerHeight-8)y=Math.max(8,r.top-h-6);
  card.style.left=x+'px';card.style.top=y+'px';
}
function hide(){card.hidden=true;cur=null}
function later(){clearTimeout(timer);timer=setTimeout(hide,180)}
document.querySelectorAll('a.tk,span.tk').forEach(function(a){
  a.addEventListener('mouseenter',function(){if(!touch)show(a)});a.addEventListener('mouseleave',function(){if(!touch)later()});
  a.addEventListener('focus',function(){show(a)});a.addEventListener('blur',later);
  a.addEventListener('click',function(ev){if(touch&&cur!==a){ev.preventDefault();ev.stopPropagation();show(a)}});
});
card.addEventListener('mouseenter',function(){clearTimeout(timer)});card.addEventListener('mouseleave',later);
document.addEventListener('click',function(ev){if(!card.hidden&&!card.contains(ev.target)&&!(ev.target.closest&&ev.target.closest('.tk')))hide()});
document.querySelectorAll('button.copy').forEach(function(b){b.addEventListener('click',function(ev){ev.preventDefault();ev.stopPropagation();
  var t=b.getAttribute('data-text');function ok(){var o=b.textContent;b.textContent='Copied';setTimeout(function(){b.textContent=o},1200)}
  try{navigator.clipboard.writeText(t).then(ok,function(){sel(b)})}catch(e){sel(b)}})});
function sel(b){var c=b.previousElementSibling;if(c&&window.getSelection){var r=document.createRange();r.selectNodeContents(c);var s=getSelection();s.removeAllRanges();s.addRange(r)}}
})();
"""

STATE_WORD = {"met": "met", "agent": "agent", "owner": "you", "na": "n/a", "gap": "GAP"}
STATE_CLASS = {"met": "ok", "agent": "", "owner": "warn", "na": "", "gap": "bad"}


def agent_pointer(model: dict, board: Board) -> str:
    work = model["agent_work"]
    if not board.ok:
        return "<span class=\"muted\">Unknown: the board could not be read.</span>"
    if not work:
        return "<span class=\"muted\">None open.</span>"
    return f"<a href=\"#agent-work\">{len(work)} agent ticket{'s' if len(work) != 1 else ''} still open</a>, listed once above."


def agent_section(model: dict, board: Board, linker: Linker) -> str:
    work = model["agent_work"]
    out = ["<section class=\"agentwork\" id=\"agent-work\"><div class=\"f\"><h4>Agent work still open</h4>"]
    if not board.ok:
        out.append("<p class=\"muted\">The board could not be read, so this list is unknown.</p>")
    elif not work:
        out.append("<p class=\"muted\">None: no launch-critical ticket and no owner-filed High or Urgent bug is open.</p>")
    else:
        out.append(f"<p class=\"muted\">{len(work)} open launch-critical ticket{'s' if len(work) != 1 else ''} and owner-filed High or Urgent bug{'s' if len(work) != 1 else ''} stand between the product and the publish step.</p><ul class=\"agent\">")
        for t in work:
            out.append(f"<li>{linker.chip(t['ref'])} <span>{inline(t['title'])}</span><span class=\"pill{' warn' if t['waiting'] else ''}\">{esc(t['lane'])}{' - waiting on you' if t['waiting'] else ''}</span>"
                       + (f"<span class=\"pill bad\">{esc(t['why'])}</span>" if t["why"] != "launch-critical" else "") + "</li>")
        out.append("</ul>")
    out.append("</div></section>")
    return "".join(out)


def render_page(model: dict, linker: Linker, board: Board, reply_hint: str, now_dt: datetime, driver_commit: str) -> str:
    L = linker.text
    mp_names = model["marketplace_names"]
    out: list[str] = []
    w = out.append
    w("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    w(f"<title>{esc(model['product'])} launch dashboard</title><style>{CSS}</style></head><body><div class=\"wrap\">")
    c = model["counts"]
    w("<header><div class=\"eyebrow\">Launch dashboard</div>")
    w(f"<h1>{esc(model['product'])}</h1>")
    if model["finish_line"]:
        w(f"<p class=\"lede\"><b>Finish line.</b> {L(model['finish_line'])}</p>")
    w("<div class=\"pills\">" + ("".join(f"<span class=\"pill\">{esc(n)}</span>" for n in mp_names.values()) or "<span class=\"pill warn\">no marketplace declared</span>") + "</div>")
    w(f"<ul class=\"stats\"><li><b>{c['open']}</b> steps left</li><li><b>{c['done']}</b> done</li><li><b>{c['gaps']}</b> gaps</li></ul>")
    w(f"<div class=\"meta\"><span>Last refreshed <b>{esc(et(now_dt))}</b></span>" + (f"<span>Epic {L(model['epic'])}</span>" if model["epic"] else "") + "</div>")
    w(f"<p class=\"reply\">{reply_hint}</p></header>")
    if model["gaps"]:
        gaps = model["gaps"]
        kinds: dict[str, int] = {}
        for g in gaps:
            kinds[g["kind"]] = kinds.get(g["kind"], 0) + 1
        names = {"catalog": "store requirements without a verified entry", "waiting": "tickets waiting on you with no step", "publish": "missing publish steps",
                 "item": "steps that break a rule", "unreadable": "unreadable ticket groups", "marketplace": "no marketplace declared", "board": "board unreadable"}
        w(f"<div class=\"banner bad\" role=\"alert\"><strong>Incomplete: {len(gaps)} gap{'s' if len(gaps) != 1 else ''} before this page proves the product can be published</strong>"
          f"<span class=\"muted\">{esc('; '.join(f'{n} {names.get(k, k)}' for k, n in kinds.items()))}. Every gap is the PM's work.</span><ul>")
        shown = gaps[:BANNER_SHOWN]
        for g in shown:
            w(f"<li>{L(g['text'])}</li>")
        if len(gaps) > len(shown):
            w(f"</ul><details><summary>Show the other {len(gaps) - len(shown)} gaps</summary><ul>")
            for g in gaps[BANNER_SHOWN:]:
                w(f"<li>{L(g['text'])}</li>")
        w("</ul>" + ("</details>" if len(gaps) > len(shown) else "") + "</div>")
    else:
        w("<div class=\"banner ok\"><strong>Complete: every barrier is on this page</strong>Checking off the steps below leaves only agent work between the product and publication.</div>")
    w("<h2>Your runbook</h2><div class=\"steps\">")
    if not model["items"]:
        w("<p class=\"muted\">No steps yet. The PM adds each step only you can take, in order, with every click spelled out.</p>")
    agent_listed = False
    for it in model["items"]:
        if it.get("kind") == "publish" and not agent_listed:
            agent_listed = True  # the list goes up once, right before the first publish item; every publish card points to it
            w(agent_section(model, board, linker))
        done = it.get("status") == "done"
        n = it["number"]
        tags = [f"<span class=\"pill\">{esc(it.get('kind'))}</span>"]
        if it.get("marketplace"):
            tags.append(f"<span class=\"pill\">{esc(mp_names.get(it['marketplace'], it['marketplace']))}</span>")
        if it.get("after"):
            nums = {i['id']: i['number'] for i in model["items"]}
            tags.append("<span class=\"muted\" style=\"font-size:.78rem\">after " + ", ".join(f"<a href=\"#step-{nums[a]}\">step {nums[a]}</a>" if a in nums else esc(a) for a in it["after"]) + "</span>")
        if done:
            tags.append("<span class=\"pill ok\">checked by the PM</span>")
        if it["problems"]:
            tags.append("<span class=\"pill bad\">breaks a rule</span>")
        w(f"<details class=\"step{' done' if done else ''}\" id=\"step-{n}\"{'' if done else ' open'}><summary><span class=\"num\">{n}</span>"
          f"<span class=\"sum\"><span class=\"t\"><span class=\"box\"></span>{L(it.get('title'))}</span><span class=\"tags\">{''.join(tags)}</span></span></summary><div class=\"body\">")
        for p in it["problems"]:
            w(f"<div class=\"f\"><span class=\"pill bad\">rule</span> {inline(p)}</div>")
        if it.get("why"):
            w(f"<div class=\"f\"><h4>Why</h4><p>{L(it['why'])}</p></div>")
        if isinstance(it.get("steps"), list):
            w("<div class=\"f\"><h4>Steps</h4><ol>" + "".join(f"<li>{L(s)}</li>" for s in it["steps"]) + "</ol></div>")
        if it.get("reply"):
            w(f"<div class=\"f\"><h4>When done, reply</h4><p><code>{esc(it['reply'])}</code><button type=\"button\" class=\"copy\" data-text=\"{esc(it['reply'])}\">Copy</button></p></div>")
        if it.get("done_when"):
            w(f"<div class=\"f\"><h4>The PM checks</h4><p>{L(it['done_when'])}</p></div>")
        if it.get("recommend"):
            w(f"<div class=\"f\"><h4>Recommendation</h4><p>{L(it['recommend'])}</p></div>")
        w(f"<div class=\"f\"><h4>If you say nothing</h4><p>{L(it['default']) if is_str(it.get('default')) else '<span class=\"muted\">Nothing happens. This step waits for you.</span>'}</p></div>")
        if it.get("refs"):
            w("<div class=\"f\"><h4>Tickets</h4><p>" + " ".join(linker.chip(r) for r in it["refs"]) + "</p></div>")
        if it.get("covers"):
            titles = {r["id"]: r["title"] for r in model["requirements"]}
            w("<div class=\"f\"><h4>Covers</h4><p>" + "; ".join(esc(titles.get(c, c)) for c in it["covers"]) + "</p></div>")
        arts = [a for a in it.get("artifacts") or [] if isinstance(a, dict) and is_str(a.get("url")) and a["url"].startswith("https://")]
        if arts:
            w("<div class=\"f\"><h4>Links</h4><ul>" + "".join(f"<li><a href=\"{esc(a['url'])}\" target=\"_blank\" rel=\"noopener\">{esc(a.get('label') or a['url'])}</a></li>" for a in arts) + "</ul></div>")
        if done:
            w(f"<div class=\"f\"><h4>Evidence</h4><p>{L(it.get('evidence'))}" + (f" <span class=\"muted\">(verified {esc(et(LP.parse_ts(it['verified_at'])))})</span>" if it.get("verified_at") else "") + "</p></div>")
        if it.get("kind") == "publish":
            w(f"<div class=\"f\"><h4>Agent work</h4><p>{agent_pointer(model, board)}</p></div>")
        w("</div></details>")
    w("</div>")
    w("<h2>Store checklist</h2>")
    for mp in model["marketplaces"]:
        rows = [r for r in model["requirements"] if r["marketplace"] == mp]
        w(f"<h3>{esc(mp_names.get(mp, mp))}</h3><p class=\"muted\" style=\"margin:4px 0 10px\">Checked against the store's own documentation on {esc(model['catalog_checked'])}.</p>")
        w("<div class=\"tablewrap\"><table><thead><tr><th>Requirement</th><th>Status</th><th>Detail</th></tr></thead><tbody>")
        for r in rows:
            e = r["entry"]
            st = r["state"]
            if st == "met":
                detail = L(e.get("evidence"))
            elif st == "agent":
                detail = linker.chip(e["ref"]) if e.get("ref") else ""
            elif st == "owner":
                detail = f"<a href=\"#step-{r['step']}\">step {r['step']}</a>" if r["step"] else esc(e.get("item"))
            elif st == "na":
                detail = L(e.get("why"))
            else:
                detail = inline(r["problem"]) if r["problem"] else "No entry yet"
            cond = "" if r["applies_when"] == "always" else f"<span class=\"sub\">Applies when: {esc(r['applies_when'])}</span>"
            doc = f" <a href=\"{esc(r['doc_url'])}\" target=\"_blank\" rel=\"noopener\">docs</a>" if r["doc_url"] else ""
            cav = f"<span class=\"sub\">{inline(r['caveat'])}</span>" if r["caveat"] else ""
            w(f"<tr><td>{inline(r['title'])}{doc}{cond}{cav}</td><td><span class=\"pill {STATE_CLASS[st]}\">{STATE_WORD[st]}</span></td><td>{detail}</td></tr>")
        w("</tbody></table></div>")
    if not model["marketplaces"]:
        w("<p class=\"muted\">Declare a marketplace and the store checklist appears here.</p>")
    w(f"<footer><span>{esc(SCHEMA)}</span>" + (f"<span>{len(board.stale_cards)} ticket card(s) may be out of date</span>" if board.stale_cards else "") + f"<span>Rendered {esc(et(now_dt))}</span><span>Driver {esc(driver_commit)}</span><a href=\"dashboard.json\">dashboard.json</a></footer>")
    cards = {r: {k: t.get(k, "") for k in ("title", "lane", "pri", "gist", "waiting", "url")} for r, t in board.tickets.items() if r in linker.used}
    blob = json.dumps(cards, ensure_ascii=False).replace("</", "<\\/")
    w(f"</div><script type=\"application/json\" id=\"tk-data\">{blob}</script><script>{JS}</script></body></html>")
    return "".join(out)


def driver_commit() -> str:
    try:
        r = subprocess.run(["git", "-C", str(HERE), "log", "-1", "--format=%h", "--", "launch-dashboard.py"], capture_output=True, text=True, timeout=15)
        return r.stdout.strip() or "unversioned"
    except Exception:
        return "unversioned"


# ------------------------------------------------------------------------------------ pipeline

def wanted_refs(data: dict, prefixes: set[str]) -> set[str]:
    out: set[str] = set()
    for it in data["items"]:
        if isinstance(it, dict):
            out |= refs_in_item(it, prefixes)
    for entry in data["requirements"].values():
        if isinstance(entry, dict):
            if isinstance(entry.get("ref"), str):
                out.add(entry["ref"])
            for key in ("evidence", "why"):
                for m in REF_ANY.finditer(str(entry.get(key) or "")):
                    if not prefixes or m.group(1) in prefixes:
                        out.add(m.group(0))
    return out


def render(repo: Path, decl: dict, data: dict, out_dir: Path) -> tuple[dict, Board]:
    catalog = load_catalog()
    proj = project_info(repo)
    prefixes = ticket_prefixes(repo, decl)
    board = gather(repo, decl, proj, wanted_refs(data, prefixes), cache_file=CARDS_FILE)
    repoidx = RepoIndex(repo, decl)
    model = build_model(repo, decl, data, catalog, board, repoidx, proj, prefixes)
    linker = Linker(board, repoidx, prefixes, proj)
    bot = bot_username()
    reply_hint = (f"Reply to the PM on Telegram (<b>@{esc(bot)}</b>), or comment on the linked ticket." if bot else "Reply to the PM, or comment on the linked ticket.")
    when = now()
    page = render_page(model, linker, board, reply_hint, when, driver_commit())
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "index.html").write_text(page)
    mirror = {k: v for k, v in model.items()}
    mirror.update(generated_at=iso(when), tickets={r: t for r, t in board.tickets.items() if r in linker.used},
                  url=(data.get("published") or {}).get("url", ""))
    write_json(out_dir / "dashboard.json", mirror)
    return model, board


def publish(repo: Path, decl: dict, site: Path, first: bool) -> tuple[bool, str]:
    proj = project_info(repo)
    date = (decl.get("declared") or "")[:10] or LP.today()
    argv = [sys.executable, str(PUBLISHER), str(site), "--name", "launch-dashboard", "--project", proj["id"], "--date", date]
    if not first:
        argv.append("--no-index")
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=240)
    except Exception as e:
        return False, f"{type(e).__name__}: {e}"[:200]
    lines = [l for l in r.stdout.strip().splitlines() if l.strip()]
    url = lines[-1].strip() if lines else ""
    if r.returncode != 0 or not url.startswith("https://"):
        return False, ((r.stderr or r.stdout).strip().splitlines() or ["publisher failed"])[-1][:200]
    return True, url


class Locked:
    def __enter__(self):
        LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        self.fh = open(LOCK_FILE, "w")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


def read_trouble(board: Board) -> str:
    """The receipt's one line on ticket-card trouble: reads that failed, reads skipped, cards served stale, cards with nothing."""
    if not (board.failed_reads or board.skipped_reads or board.stale_cards or board.unreadable):
        return ""
    stale = [r for r in board.stale_cards if r not in board.unreadable]
    parts = []
    if board.failed_reads:
        parts.append(f"{len(board.failed_reads)} ticket read(s) failed")
    if board.skipped_reads:
        parts.append(f"{len(board.skipped_reads)} not read (the {READ_BUDGET}s budget ran out)")
    if stale:
        parts.append(f"{len(stale)} card(s) from stale cache ({', '.join(stale[:6])}{'...' if len(stale) > 6 else ''})")
    if board.unreadable:
        parts.append(f"{len(board.unreadable)} card(s) unreadable ({', '.join(board.unreadable[:6])}{'...' if len(board.unreadable) > 6 else ''}): the page shows a gap and is not Complete")
    return "; ".join(parts)


def run_apply(repo: Path, decl: dict, ops, do_publish: bool = True) -> list[dict]:
    """Apply `ops` (may be empty), re-render and publish. Returns receipt entries; a publish failure never raises."""
    entries: list[dict] = []
    if decl.get("mode") != "launch":  # the dashboard is launch-only: inert in develop, polish and live
        return entries
    with Locked():
        data = load_data(DATA_FILE)
        if ops not in (None, []):
            entries += apply_ops(data, ops, load_catalog(), ticket_prefixes(repo, decl))
            if any(e["status"] == "ok" for e in entries):
                write_json(DATA_FILE, data)
        try:
            model, board = render(repo, decl, data, SITE_DIR)
        except Exception as e:
            entries.append({"op": "dashboard", "ref": "render", "status": "error", "detail": f"{type(e).__name__}: {e}"[:200]})
            return entries
        detail = f"{model['counts']['open']} open, {model['counts']['done']} done, {model['counts']['gaps']} gaps"
        trouble = read_trouble(board)
        if trouble:
            detail += "; " + trouble
        entries.append({"op": "dashboard", "ref": "render", "status": "ok", "detail": detail})
        if do_publish:
            ok, msg = publish(repo, decl, SITE_DIR, first=not (data.get("published") or {}).get("url"))
            if ok:
                data["published"] = {"url": msg, "at": iso(now())}
                write_json(DATA_FILE, data)
                site = read_json(SITE_DIR / "dashboard.json", {})
                site["url"] = msg
                write_json(SITE_DIR / "dashboard.json", site)
            entries.append({"op": "dashboard", "ref": "publish", "status": "ok" if ok else "error", "detail": msg})
    return entries


# ------------------------------------------------------------------------------------------ brief

OPS_SHAPE = """\
Dashboard ops go in the plan as "dashboard": [ ... ] (omit it when nothing changed). Shape:
  {"op": "upsert", "item": {"id": "play-create-app", "order": 50, "title": "Create the app in Play Console", "why": "...",
     "kind": "console", "marketplace": "google_play", "steps": ["Open https://... and ...", "..."], "reply": "Play app created",
     "done_when": "what you will read to check it", "recommend": "...", "default": null, "refs": ["ABC-1"],
     "artifacts": [{"label": "...", "url": "https://..."}], "after": ["other-id"], "covers": ["gp.create-app"]}},
  {"op": "check", "id": "play-create-app", "evidence": "link or one-line read-back"},
  {"op": "uncheck", "id": "...", "why": "..."},   {"op": "remove", "id": "...", "why": "..."},
  {"op": "requirement", "id": "gp.data-safety", "status": "met|agent|owner|na", "evidence|ref|item|why": "..."},
  {"op": "marketplaces", "value": ["google_play", "app_store"]}
Rules: docs/launch-dashboard.md. kind is one of """ + ", ".join(KINDS) + """. An item is only ever done after you read `done_when`."""


def brief_section(repo: Path, decl: dict, rows: list[dict] | None = None) -> str:
    data = load_data(DATA_FILE)
    catalog = load_catalog()
    proj = project_info(repo)
    prefixes = ticket_prefixes(repo, decl)
    board = gather(repo, decl, proj, wanted_refs(data, prefixes), rows=rows)
    ctx = item_ctx(data, catalog, prefixes)
    broken = broken_items(data, ctx)
    gaps = compute_gaps(data, catalog, board, decl, broken, prefixes)
    items = order_items([i for i in data["items"] if isinstance(i, dict) and isinstance(i.get("id"), str)])
    done = [i for i in items if i.get("status") == "done"]
    left = [i for i in items if i.get("status") != "done"]
    url = (data.get("published") or {}).get("url") or "not published yet (the apply publishes it)"
    out = [f"\n# Launch dashboard ({url})",
           "The owner's runbook: every step you cannot finish without him. The rules are in docs/launch-dashboard.md; the driver enforces them. "
           "A step is Jarad's only when no agent path exists. Never add a verify-the-build step. Check a step only after you read its `done_when`.",
           f"Marketplaces: {', '.join(data['marketplaces']) or 'NONE DECLARED'} (catalog: {', '.join((catalog.get('marketplaces') or {}).keys())}). "
           f"Steps: {len(left)} open, {len(done)} done, {len(gaps)} gaps."]
    if left:
        out.append("Open steps (n|id|kind|title):")
        out += [f"{n}|{i['id']}|{i.get('kind')}|{str(i.get('title'))[:90]}" for n, i in enumerate(items, 1) if i.get("status") != "done"]
    if gaps:
        out.append("GAPS: every one is work for this pass. Close it by adding a step, filing an agent ticket in the launch epic, or recording evidence with a `requirement` op:")
        out += [f"- [{g['kind']}] {g['text']}" for g in gaps[:60]]
        if len(gaps) > 60:
            out.append(f"+{len(gaps) - 60} more gaps: closing the first batch shows the rest next pass")
    else:
        out.append("No gaps: the dashboard is complete.")
    out.append(OPS_SHAPE)
    return "\n".join(out)


# ------------------------------------------------------------------------------------------- main

def check(repo: Path, decl: dict, data_path: Path) -> int:
    catalog = load_catalog()
    data = load_data(data_path)
    ctx = item_ctx(data, catalog, ticket_prefixes(repo, decl))
    problems: list[str] = []
    if catalog.get("error"):
        problems.append(catalog["error"])
    seen = set()
    for req in catalog["requirements"]:
        for key in ("id", "marketplace", "title", "applies_when", "why", "owner_only", "owner_steps", "verify", "doc_url", "checked"):
            if key not in req:
                problems.append(f"catalog row {req.get('id', '?')} lacks `{key}`")
        if req.get("id") in seen:
            problems.append(f"catalog id {req.get('id')} is duplicated")
        seen.add(req.get("id"))
    for iid, probs in broken_items(data, ctx).items():
        problems += [f"item {iid}: {p}" for p in probs]
    ids = {i.get("id") for i in data["items"] if isinstance(i, dict)}
    for rid, entry in data["requirements"].items():
        if rid not in ctx["catalog_ids"]:
            problems.append(f"requirement {rid}: not a catalog id")
        else:
            why = requirement_problem(entry, ids)
            if why:
                problems.append(f"requirement {rid}: {why}")
    for mp in data["marketplaces"]:
        if mp not in ctx["marketplaces"]:
            problems.append(f"marketplace {mp!r} is not in the catalog")
    print(json.dumps({"schema": SCHEMA, "ok": not problems, "problems": problems, "items": len(data["items"]),
                      "requirements": len(data["requirements"]), "catalog_rows": len(catalog["requirements"])}, indent=2))
    return 0 if not problems else 1


def flag(name: str) -> str | None:
    return LP._flag(name)


def main(argv: list[str]) -> int:
    modes = [a for a in argv[1:] if a in ("--check", "--ops", "--render", "--publish", "--brief")]
    if len(modes) != 1:
        print(__doc__)
        return 2
    mode = modes[0]
    repo = LP.find_repo()
    decl = LP.load_declaration(repo)
    if decl["mode"] != "launch":  # launch-only: `active` also covers polish, and the dashboard stays inert there
        print(f"launch-mode: {decl['mode']}: the dashboard is inert, nothing done.")
        return 0
    data_path = Path(flag("--data")) if flag("--data") else DATA_FILE
    if mode == "--check":
        return check(repo, decl, data_path)
    if mode == "--brief":
        print(brief_section(repo, decl))
        return 0
    if mode == "--render":
        out_dir = Path(flag("--out")) if flag("--out") else SITE_DIR
        model, _ = render(repo, decl, load_data(data_path), out_dir)
        print(f"rendered {out_dir / 'index.html'}: {model['counts']['open']} open, {model['counts']['done']} done, {model['counts']['gaps']} gaps, "
              f"{'complete' if model['complete'] else 'incomplete'}")
        return 0
    if mode == "--publish":
        entries = run_apply(repo, decl, None)
    else:
        path = flag("--ops")
        try:
            body = json.loads(Path(path).read_text()) if path else None
        except (OSError, ValueError) as e:
            print(f"OPS UNREADABLE: {e}. Nothing applied.")
            return 1
        ops = body.get("dashboard", body.get("ops")) if isinstance(body, dict) else body
        entries = run_apply(repo, decl, ops)
    for e in entries:
        print(f"{e['op']} {e.get('ref', '')}: {e['status']}: {e['detail']}")
    return 1 if any(e["status"] == "error" for e in entries) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
