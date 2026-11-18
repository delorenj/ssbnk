#!/usr/bin/env python3
"""launch-pass: the repo-agnostic launch-mode driver every PM role ships.

An interval driver (the interval-driver skill). A script, not the model, holds the context. Launch
mode is DECLARED by a committed file at the repo root, `.launch.yaml`; this script never guesses it
and never edits it. No file, or any mode other than `launch`, means steady state: the snapshot is
the single line `launch-mode: steady`, so the unchanged snapshot costs 0 tokens.

  launch-pass.py --monitor         stable snapshot (Hermes hashes it; unchanged = the agent never starts)
  launch-pass.py --brief           the pass contract, the declaration, the rules pointer, the snapshot,
                                   the untagged comments waiting, the roadmap and the plan schema
  launch-pass.py --apply [PLAN]    apply the agent's plan (default runtime/launch-pass.json) under the
                                   board-driver lease, with a write cap and a receipt
  launch-pass.py --check           parse and print the declaration as JSON (debugging; exit 1 if broken)

Declaration (`.launch.yaml`, no status inside):
  mode: launch | steady          declared: YYYY-MM-DD       source: "<doc + owner decision>"
  finish_line: "<what launched means>"    target_date: YYYY-MM-DD or empty
  contract: [<repo-relative paths>]       epic: <BOARD-n>
  cut_line:                      # optional ranking hint; the board stays the truth
    launch_critical: [..]
    after_launch: [..]

Allowed apply ops: comment, create, move, close, cancel, rank, link. Everything else is refused.
`rank` has no px verb (px cannot reorder a lane), so it degrades to a `launch rank N` comment and the
receipt says so. Moves are Backlog/Todo only: In Progress is Krebs' lane. px refuses an epic at either
end of a link or as a parent, so a `link` touching the declaration's epic, or a `create` whose `parent`
is that epic, becomes an epic membership (`px epic add EPIC REF`). Every ref (`ref`, `other`, `parent`) must
be on this board; a ticket carrying `agent:working` is never moved, closed or cancelled; `comment`, `close`
and `cancel` need a `text`; create labels are bare words or a fleet open axis (risk:, needs:, xp:). A write
whose fields have the wrong types is skipped, and the receipt is written whatever happens.

stdlib only, python3. The script lives in <repo>/agents/hermes/<role>/.scripts/ and finds the repo by
walking up to `.project.json` (or `.git`); LAUNCH_REPO or --repo override. px runs with cwd = repo.
Env: LAUNCH_PASS_DATE (YYYY-MM-DD, tests), LAUNCH_PASS_MAX (write cap, default 12),
LAUNCH_LEASE_WAIT (seconds to wait for a held lease, default 45).
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROLE_DIR = HERE.parent
ROLE = ROLE_DIR.name
RT = ROLE_DIR / "runtime"
LEASE_SCRIPT = HERE / "board-lease.py"
PROMPT = HERE / "launch-pass.prompt.md"
ROADMAP = RT / "launch-roadmap.md"
DEFAULT_PLAN = RT / "launch-pass.json"
RECEIPTS = RT / "launch-receipts"
OPEN = {"backlog", "unstarted", "started"}
ALLOWED_OPS = ("comment", "create", "move", "close", "cancel", "rank", "link")
LANES = ("Backlog", "Todo")
PRIORITIES = ("urgent", "high", "medium", "low", "none")
REF = re.compile(r"^([A-Z][A-Z0-9]*)-(\d+)$")
MAX_CREATES = 3
ROADMAP_LINES = 40
STALE_HOURS = 48
AGENT_COMMENT = re.compile(r"^(\[[A-Za-z0-9 _:.-]+\]|krebs\b|hermes\b|momo\b)", re.I)
OWNER_BLOCKING = ("urgent", "high")
# board-taxonomy: a colon label is a closed, declared axis. A create may carry bare words and the fleet's
# open facet axes only; lifecycle:/agent: are automation's, repo: is px's, epic: would mint an epic.
OPEN_AXES = ("risk:", "needs:", "xp:")
STRING_FIELDS = ("ref", "other", "parent", "text", "title", "description", "key", "lane", "state", "priority")
NEEDS_TEXT = ("comment", "close", "cancel")


# --------------------------------------------------------------------------------------- time

def now() -> datetime:
    return datetime.now(timezone.utc)


def et_zone():
    try:
        from zoneinfo import ZoneInfo
        return ZoneInfo("America/New_York")
    except Exception:
        return timezone.utc


def today() -> str:
    forced = os.environ.get("LAUNCH_PASS_DATE", "").strip()
    return forced or now().astimezone(et_zone()).strftime("%Y-%m-%d")


def parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def et_date(value: str) -> str:
    return parse_ts(value).astimezone(et_zone()).strftime("%Y-%m-%d")


# ---------------------------------------------------------------------- repo + declaration

def find_repo() -> Path:
    for override in (os.environ.get("LAUNCH_REPO"), _flag("--repo")):
        if override:
            return Path(override).resolve()
    for d in [ROLE_DIR, *ROLE_DIR.parents]:
        if (d / ".project.json").is_file():
            return d
    for d in [ROLE_DIR, *ROLE_DIR.parents]:
        if (d / ".git").exists():
            return d
    return ROLE_DIR.parents[2] if len(ROLE_DIR.parents) > 2 else ROLE_DIR


def _flag(name: str) -> str | None:
    if name in sys.argv:
        i = sys.argv.index(name)
        if i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return None


def _strip_comment(line: str) -> str:
    quote = ""
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def _split_inline(body: str) -> list[str]:
    parts, buf, quote = [], "", ""
    for ch in body:
        if quote:
            buf += ch
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
            buf += ch
        elif ch == ",":
            parts.append(buf)
            buf = ""
        else:
            buf += ch
    if buf.strip():
        parts.append(buf)
    return parts


def _scalar(value: str):
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        return [_scalar(p) for p in _split_inline(value[1:-1])]
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        inner = value[1:-1]
        return inner.replace('\\"', '"').replace("\\\\", "\\") if value[0] == '"' else inner.replace("''", "'")
    if value in ("~", "null", "Null", "NULL"):
        return ""
    return value


def parse_yaml(text: str) -> dict:
    """The tiny YAML subset `.launch.yaml` uses: scalars, inline and block lists, one nested map."""
    out: dict = {}
    top: str | None = None   # open top-level key
    sub: str | None = None   # open key inside a nested map
    for raw in text.splitlines():
        line = _strip_comment(raw).rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        body = line.strip()
        if indent == 0:
            if ":" not in body:
                raise ValueError(f"not a key: {body!r}")
            key, _, val = body.partition(":")
            key = key.strip()
            top, sub = key, None
            out[key] = _scalar(val) if val.strip() else None
            continue
        if top is None:
            raise ValueError(f"indented line with no parent: {body!r}")
        if body.startswith("- "):
            item = _scalar(body[2:])
            if sub is not None:
                container = out[top]
                if not isinstance(container, dict):
                    raise ValueError(f"list item under non-map {top}")
                if not isinstance(container.get(sub), list):
                    container[sub] = []
                container[sub].append(item)
            else:
                if not isinstance(out[top], list):
                    out[top] = []
                out[top].append(item)
            continue
        if ":" not in body:
            raise ValueError(f"not a key: {body!r}")
        key, _, val = body.partition(":")
        if not isinstance(out[top], dict):
            out[top] = {}
        key = key.strip()
        out[top][key] = _scalar(val) if val.strip() else None
        sub = key
    return out


def _list(value) -> list[str]:
    if value in (None, ""):
        return []
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    return [str(value).strip()]


def load_declaration(repo: Path) -> dict:
    """Always returns a dict with `active` (bool), never raises: no file or a broken file is steady."""
    path = repo / ".launch.yaml"
    decl = {"active": False, "path": str(path), "error": "", "raw": "", "mode": "steady"}
    try:
        raw = path.read_text()
    except OSError:
        return decl
    decl["raw"] = raw
    try:
        data = parse_yaml(raw)
    except ValueError as e:
        decl["error"] = str(e)
        return decl
    mode = str(data.get("mode") or "").strip().lower()
    cut = data.get("cut_line") if isinstance(data.get("cut_line"), dict) else {}
    decl.update(
        mode=mode or "steady",
        active=mode == "launch",
        declared=str(data.get("declared") or ""),
        source=str(data.get("source") or ""),
        finish_line=str(data.get("finish_line") or ""),
        target_date=str(data.get("target_date") or ""),
        contract=_list(data.get("contract")),
        epic=str(data.get("epic") or "").strip(),
        launch_critical=_list(cut.get("launch_critical")),
        after_launch=_list(cut.get("after_launch")),
        sha=hashlib.sha256(raw.encode()).hexdigest()[:12],
    )
    return decl


def project(repo: Path) -> dict:
    try:
        return json.loads((repo / ".project.json").read_text())
    except Exception:
        return {}


def agent_id(repo: Path) -> str:
    m = re.search(r'^agent_id:\s*"?([^"\n]+)"?', _read(ROLE_DIR / "role.yaml"), re.M)
    return m.group(1).strip() if m else f"{repo.name}-{ROLE}"


def _read(p: Path) -> str:
    try:
        return p.read_text()
    except OSError:
        return ""


def tag() -> str:
    return f"[{ROLE}]"


# --------------------------------------------------------------------------------------- px

def px_run(repo: Path, *args: str, timeout: int = 120):
    return subprocess.run(["px", *args], cwd=str(repo), capture_output=True, text=True, timeout=timeout)


def px_json(repo: Path, *args: str) -> dict:
    r = px_run(repo, *args, "--json", timeout=60)
    return json.loads(r.stdout)


def px_write(repo: Path, *args: str) -> tuple[bool, str]:
    try:
        r = px_run(repo, *args)
    except Exception as e:  # missing px, timeout
        return False, f"{type(e).__name__}: {e}"
    first = ((r.stdout or r.stderr).strip().splitlines() or ["(no output)"])[0]
    return r.returncode == 0, first[:240]


def comment_text(c: dict) -> str:
    raw = c.get("text") or c.get("comment_html") or ""
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", raw))).strip()


def is_mine(c: dict) -> bool:
    return comment_text(c).startswith(tag())


def fetch_ticket(repo: Path, ref: str) -> dict:
    t = px_json(repo, "task", "get", ref)["ticket"]
    cs = sorted(t.get("comments") or [], key=lambda c: c.get("created_at", ""))
    mine = [c["created_at"] for c in cs if is_mine(c)]
    labels = t.get("label_names") or []
    updated = parse_ts(t["updated_at"])
    activity = updated
    # The PM's own comments bump updated_at; measure staleness from the last activity that was not ours.
    if cs and is_mine(cs[-1]) and updated - parse_ts(cs[-1]["created_at"]) <= timedelta(minutes=10):
        others = [c["created_at"] for c in cs if not is_mine(c)] or [t.get("created_at") or t["updated_at"]]
        activity = parse_ts(max(others))
    waiting = [c for c in cs if not AGENT_COMMENT.match(comment_text(c)) and c["created_at"] > (max(mine) if mine else "")]
    pri = (t.get("priority") or "none").lower()
    kind_bug = any(l in ("bug", "kind:bug") for l in labels)
    return {
        "ref": ref,
        "seq": int(ref.rsplit("-", 1)[1]),
        "name": t.get("name") or "",
        "lane": t.get("state_name") or "?",
        "group": t.get("state_group") or "",
        "pri": pri,
        "labels": labels,
        "bug": kind_bug,
        # Every Plane write is the operator's account, so origin is a heuristic: a ticket made with an
        # idempotency key (external_id) was filed by an agent; anything else is treated as the owner's.
        "origin": "agent" if (t.get("external_id") or t.get("external_source")) else "owner",
        "working": "agent:working" in labels,
        "review": "lifecycle:review" in labels,
        "held": any(l in labels for l in ("lifecycle:needs-input", "lifecycle:blocked", "agent:failed")),
        "activity": activity,
        "waiting": waiting,
        "comments": cs,
    }


def board(repo: Path) -> tuple[str, list[dict]]:
    listing = px_json(repo, "task", "list")
    ident = str(listing.get("board") or "")
    refs = [f"{ident}-{i['sequence_id']}" for i in listing.get("issues", []) if i.get("state_group") in OPEN]
    with ThreadPoolExecutor(8) as pool:
        rows = sorted(pool.map(lambda r: fetch_ticket(repo, r), refs), key=lambda r: r["seq"])
    return ident, rows


def occupies_slot(r: dict) -> bool:
    return r["group"] == "started" and not r["review"] and not r["held"]


def stale(r: dict) -> bool:
    return (r["working"] or occupies_slot(r)) and now() - r["activity"] > timedelta(hours=STALE_HOURS)


def launch_blocker(r: dict) -> bool:
    return r["bug"] and r["origin"] == "owner" and r["pri"] in OWNER_BLOCKING


# ----------------------------------------------------------------------------------- snapshot

def target_line(decl: dict) -> str:
    t = decl.get("target_date") or ""
    if not t:
        return "target none"
    try:
        days = (datetime.strptime(t, "%Y-%m-%d").date() - datetime.strptime(today(), "%Y-%m-%d").date()).days
        return f"target {t} ({days}d)"
    except ValueError:
        return f"target {t}"


def snapshot_lines(decl: dict, rows: list[dict] | None) -> list[str]:
    lines = [
        "launch-mode: launch",
        f"date {today()}",
        f"declaration {decl['sha']}",
        f"epic {decl.get('epic') or 'none'}",
        target_line(decl),
    ]
    if rows is None:
        return lines + ["board UNAVAILABLE"]
    lc, al = set(decl["launch_critical"]), set(decl["after_launch"])
    for r in rows:
        flags = ",".join(f for f, on in (("review", r["review"]), ("held", r["held"]), ("working", r["working"])) if on) or "-"
        cut = "lc" if r["ref"] in lc else "al" if r["ref"] in al else "-"
        lines.append("|".join([
            r["ref"], r["lane"], r["pri"], "bug" if r["bug"] else "-", flags, r["origin"], f"cut:{cut}",
            "launch-blocker" if launch_blocker(r) else "-", f"owner-waiting:{len(r['waiting'])}",
            "stale-claim" if stale(r) else "-",
        ]))
    if lc:
        todo = [r["ref"] for r in rows if r["lane"] == "Todo"]
        lines.append("off-cut-todo|" + (",".join(x for x in todo if x not in lc) or "-"))
        lines.append("cut-in-backlog|" + (",".join(r["ref"] for r in rows if r["ref"] in lc and r["group"] == "backlog") or "-"))
    return lines


def snapshot(repo: Path) -> tuple[dict, list[str], list[dict] | None, str]:
    decl = load_declaration(repo)
    if not decl["active"]:
        return decl, ["launch-mode: steady"], None, ""
    try:
        ident, rows = board(repo)
    except Exception:
        return decl, snapshot_lines(decl, None), None, ""
    return decl, snapshot_lines(decl, rows), rows, ident


def monitor(repo: Path) -> int:
    print("\n".join(snapshot(repo)[1]))
    return 0


# --------------------------------------------------------------------------------------- brief

PLAN_SCHEMA = """\
{"writes": [
  {"op": "comment", "ref": "<ID>-12", "text": "..."},
  {"op": "create",  "title": "...", "description": "...", "labels": ["bare-word"], "priority": "high",
                    "state": "Todo", "key": "launch:slug", "parent": "<EPIC>"},
  {"op": "move",    "ref": "<ID>-12", "lane": "Todo", "text": "why"},
  {"op": "close",   "ref": "<ID>-12", "text": "accepted: shipped in build X"},
  {"op": "cancel",  "ref": "<ID>-12", "text": "why it is not launch work and never will be"},
  {"op": "rank",    "ref": "<ID>-12", "rank": 1, "text": "why"},
  {"op": "link",    "ref": "<ID>-12", "other": "<ID>-13", "blocks": true},
  {"op": "link",    "ref": "<EPIC>", "other": "<ID>-12"}],
 "roadmap": "# whole new roadmap, at most 40 lines (omit on a quiet pass)",
 "note": "one line"}"""


def brief(repo: Path) -> int:
    decl, lines, rows, ident = snapshot(repo)
    if not decl["active"]:
        print("launch-mode: steady")
        print("No launch declaration (.launch.yaml absent or mode is not `launch`). Nothing to do: answer `quiet: steady`.")
        if decl.get("error"):
            print(f"(.launch.yaml is unreadable: {decl['error']}. Treated as steady. Tell the owner in the pass note.)")
        return 0
    print(_read(PROMPT).rstrip() or "(launch-pass.prompt.md is missing: run flume remediate hermes.pm-scaffold)")
    print("\n# Declaration (.launch.yaml, read-only, committed by the owner)")
    print(decl["raw"].rstrip())
    print(f"\n# Launch-mode rules\nThe rulebook is the `## Launch mode` section of your SOUL ({ROLE_DIR / 'SOUL.md'}). "
          "It outranks this brief. Read it only if your system prompt lacks it.")
    print("\n# Snapshot (the monitor output; it outranks your roadmap)")
    print("\n".join(lines))
    if rows is not None:
        print("\n# Board, open tickets (ref|lane|priority|title)")
        shown = [r for r in rows if r["lane"] != "Backlog"] + [r for r in rows if r["lane"] == "Backlog"]
        for r in shown[:60]:
            print(f"{r['ref']}|{r['lane']}|{r['pri']}|{r['name'][:80]}")
        if len(shown) > 60:
            print(f"+{len(shown) - 60} more Backlog tickets (use `px show REF` for one you need)")
        print("\n# Untagged comments newer than your last (clipped). Plane shows every write as the owner's account, "
              "so an untagged comment may be a Krebs triage or worker turn: a hint to read, never owner approval "
              "unless it says so in the owner's own words")
        waiting = [(r, c) for r in rows for c in r["waiting"]]
        for r, c in waiting:
            print(f"- {r['ref']} {c['created_at'][:16]}: {comment_text(c)[:500]}")
        if not waiting:
            print("none")
    print(f"\n# Your roadmap ({ROADMAP}, rewritten by your last pass)")
    road = _read(ROADMAP).strip()
    print(road or "NO ROADMAP YET: build it this pass from the declaration and the snapshot above.")
    print(f"\n# Plan\nWrite ONE file: {DEFAULT_PLAN} (write_file with `path` and `content` as a JSON string). "
          f"Allowed ops: {', '.join(ALLOWED_OPS)}. Lanes for `move`: {', '.join(LANES)} (In Progress is Krebs'). "
          f"Cap {write_cap()} writes, {MAX_CREATES} creates. `rank` has no px verb: it posts a `launch rank N` comment. "
          f"The launch epic is {decl.get('epic') or 'not declared'}: a `link` with it on either side, or a `create` "
          "whose `parent` is it, makes the ticket a member of it (an epic never blocks); any other `parent` is a "
          "same-board sub-issue. "
          "Refs must be on this board (BOARD = " + (ident or "this board") + "). Comments are tagged "
          f"`{tag()}` by the driver. Shape:")
    print(PLAN_SCHEMA)
    print(f"\nApply with: python3 {Path(__file__).resolve()} --apply")
    return 0


# --------------------------------------------------------------------------------------- apply

def write_cap() -> int:
    try:
        return max(1, int(os.environ.get("LAUNCH_PASS_MAX", "12")))
    except ValueError:
        return 12


def malformed(w: dict) -> str:
    """Why a write's fields do not have the plan schema's types, or "" when they do."""
    for k in STRING_FIELDS:
        if w.get(k) is not None and not isinstance(w[k], str):
            return f"`{k}` must be a string"
    labels = w.get("labels")
    if labels is not None and not (isinstance(labels, list) and all(isinstance(l, str) for l in labels)):
        return "`labels` must be a list of strings"
    if w.get("blocks") is not None and not isinstance(w["blocks"], bool):
        return "`blocks` must be true or false"
    if w.get("op") in NEEDS_TEXT and not (w.get("text") or "").strip():
        return f"`{w['op']}` needs a `text` saying why"
    return ""


def label_ok(label: str) -> bool:
    label = label.strip()
    if not label or label.startswith("-") or "," in label:
        return False
    return ":" not in label or label.startswith(OPEN_AXES)


def lease(cmd: str, lock: Path, owner: str, ttl: int = 300) -> bool:
    argv = [sys.executable, str(LEASE_SCRIPT), cmd, str(lock), owner]
    if cmd == "acquire":
        argv += ["--ttl", str(ttl)]
    return subprocess.run(argv, capture_output=True, text=True).returncode == 0


def take_lease(lock: Path, owner: str) -> bool:
    try:
        wait = float(os.environ.get("LAUNCH_LEASE_WAIT", "45"))
    except ValueError:
        wait = 45.0
    deadline = time.monotonic() + wait
    while True:
        if lease("acquire", lock, owner):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(min(5.0, max(0.0, deadline - time.monotonic())))


def apply(repo: Path, plan_arg: str | None) -> int:
    decl = load_declaration(repo)
    if not decl["active"]:
        print("launch-mode: steady: apply refused, nothing written.")
        return 0
    proj = project(repo)
    if (proj.get("execution") or {}).get("mode") in ("managed", "shadow"):
        print("REFUSED: this board is Krebs-managed (px writes need --actor and -f payloads); launch-pass drives legacy boards only. Nothing written.")
        return 4
    if not LEASE_SCRIPT.is_file():
        print(f"ERROR: lease script missing: {LEASE_SCRIPT}. Nothing written.", file=sys.stderr)
        return 2
    plan_path = Path(plan_arg) if plan_arg else DEFAULT_PLAN
    try:
        plan = json.loads(plan_path.read_text())
        if not isinstance(plan, dict) or not isinstance(plan.get("writes", []), list):
            raise ValueError("plan must be an object with a `writes` list")
    except Exception as e:
        print(f"PLAN UNREADABLE: {e}. Nothing written.")
        return 1
    writes = plan.get("writes") or []
    ident = (proj.get("ticket_provider") or {}).get("identifier") or ""
    owner = os.environ.get("HERMES_BOARD_LEASE_OWNER") or f"hermes:{agent_id(repo)}:launch-pass"
    lock = RT / "wip-driver.lock"
    if writes and not take_lease(lock, owner):
        print(f"LEASE HELD by someone else: nothing written ({len(writes)} planned). Plan kept at {plan_path}; run --apply again later.")
        return 3

    archive = plan_path.with_suffix(".applied.json")
    plan_path.replace(archive)  # never applied twice; the next pass's write_file sees a new file
    cap = write_cap()
    entries: list[dict] = []
    if len(writes) > cap:
        entries.append({"op": "cap", "status": "skip", "detail": f"{len(writes)} writes planned, applying the first {cap}"})
        writes = writes[:cap]

    tickets: dict[str, dict | None] = {}

    def get(ref: str) -> dict | None:
        if ref not in tickets:
            try:
                tickets[ref] = fetch_ticket(repo, ref)
            except Exception:
                tickets[ref] = None
        return tickets[ref]

    def tagged(text: str) -> str:
        text = (text or "").strip()[:1500]
        return text if text.startswith(tag()) else f"{tag()} {text}".strip()

    def record(i: int, w: dict, status: str, detail: str) -> None:
        entries.append({"i": i, "op": w.get("op"), "ref": w.get("ref", ""), "status": status, "detail": detail})

    creates = 0
    epic = str(decl.get("epic") or "")

    def on_board(r: str) -> bool:
        m = REF.match(r)
        return bool(m) and (not ident or m.group(1) == ident)

    def one(i: int, w) -> None:
        nonlocal creates
        if not isinstance(w, dict):
            return record(i, {}, "skip", "write is not an object")
        op = w.get("op")
        if op not in ALLOWED_OPS:
            return record(i, w, "skip", "op not allowed for the launch pass")
        bad = malformed(w)
        if bad:
            return record(i, w, "skip", bad)
        ref = w.get("ref") or ""
        if op != "create":
            if not REF.match(ref):
                return record(i, w, "skip", "bad ref")
            if not on_board(ref):
                return record(i, w, "skip", f"ref is not on this board ({ident})")
        text = tagged(w.get("text") or "")

        if op in ("comment", "rank"):
            if op == "rank":
                try:
                    rank = int(w.get("rank"))
                    if rank < 1 or isinstance(w.get("rank"), bool):
                        raise ValueError
                except (TypeError, ValueError):
                    return record(i, w, "skip", "rank needs an integer >= 1")
                body = tagged(f"launch rank {rank}: {(w.get('text') or '').strip()}")
            else:
                body = text
            t = get(ref)
            if t is None:
                return record(i, w, "error", "ticket unreadable")
            if any(comment_text(c) == body for c in t["comments"]):
                return record(i, w, "skip", "already posted")
            low = re.sub(r"^\[[^\]]*\]\s*", "", body).lower()
            if ref == decl.get("epic") and low.startswith("readout") and any(
                is_mine(c) and comment_text(c).lower().startswith(f"{tag()} readout".lower()) and et_date(c["created_at"]) == today()
                for c in t["comments"]
            ):
                return record(i, w, "skip", "one readout per day on the epic")
            ok, msg = px_write(repo, "comment", ref, "-m", body)
            return record(i, w, ("degraded" if op == "rank" and ok else "ok" if ok else "error"),
                          (f"px has no rank verb; posted as a comment: {msg}" if op == "rank" and ok else msg))
        if op in ("move", "close", "cancel"):
            t = get(ref)
            if t is None:
                return record(i, w, "error", "ticket unreadable")
            if t["group"] in ("completed", "cancelled"):
                return record(i, w, "skip", f"already {t['lane']}")
            if op == "move":
                if w.get("lane") not in LANES:
                    return record(i, w, "skip", f"lane {w.get('lane')!r} not in {list(LANES)}")
                if t["group"] == "started":
                    return record(i, w, "skip", "In Progress is Krebs' lane: comment instead")
            # Krebs v2: agent:working is the pickup chip's and Krebs' lease. Moving, closing or cancelling under a
            # live turn would end it behind the worker's back (and px strips the label on a close or cancel).
            if t["working"]:
                return record(i, w, "skip", "a live worker holds it (agent:working)")
            verb = ("move", ref, w["lane"], "-m", text) if op == "move" else (op, ref, "-m", text)
            ok, msg = px_write(repo, *verb)
            tickets.pop(ref, None)
            return record(i, w, "ok" if ok else "error", msg)
        if op == "link":
            other = w.get("other") or ""
            if not REF.match(other) or other == ref:
                return record(i, w, "skip", "bad or identical `other` ref")
            if not on_board(other):
                return record(i, w, "skip", f"`other` is not on this board ({ident})")
            if epic and epic in (ref, other):
                if w.get("blocks"):
                    return record(i, w, "skip", f"{epic} is the launch epic: it joins members, it never blocks")
                member = other if ref == epic else ref
                ok, msg = px_write(repo, "epic", "add", epic, member)
                return record(i, w, "ok" if ok else "error", msg)
            ok, msg = px_write(repo, "link", "add", ref, other, *(["--blocks"] if w.get("blocks") is True else []))
            return record(i, w, "ok" if ok else "error", msg)
        # create. px parses its argv with node's strict parseArgs: a positional or a `-d` value that starts
        # with `-` (a markdown bullet) is a parse error, so the title loses leading dashes and every free-text
        # value rides in the `--flag=value` form.
        title = (w.get("title") or "").strip().lstrip("-").strip()[:200]
        if not title:
            return record(i, w, "skip", "create needs a title")
        if creates >= MAX_CREATES:
            return record(i, w, "skip", f"at most {MAX_CREATES} creates per pass")
        state = w.get("state") or "Backlog"
        pri = (w.get("priority") or "").lower()
        if state not in LANES or (pri and pri not in PRIORITIES):
            return record(i, w, "skip", f"state must be one of {list(LANES)} and priority one of {list(PRIORITIES)}")
        parent = w.get("parent") or ""
        join_epic = bool(epic) and parent == epic
        if parent and not join_epic and not on_board(parent):
            return record(i, {**w, "ref": title[:60]}, "skip", f"parent {parent!r} is not a ticket on this board ({ident})")
        wanted = [l.strip() for l in (w.get("labels") or [])]
        labels = [l for l in wanted if label_ok(l)]
        key = (w.get("key") or "").strip().lstrip("-").strip() or "launch:" + hashlib.sha1(title.lower().encode()).hexdigest()[:12]
        args = ["task", "create", title, "--state", state, "--idempotency-source", "launch-pass", "--idempotency-key", key]
        if (w.get("description") or "").strip():
            args.append("--description=" + w["description"])
        if labels:
            args += ["-l", ",".join(labels)]
        if pri:
            args += ["--priority", pri]
        if parent and not join_epic:
            args += ["--parent", parent]
        creates += 1
        ok, msg = px_write(repo, *args)
        dropped = [l for l in wanted if l and l not in labels]
        record(i, {**w, "ref": title[:60]}, "ok" if ok else "error",
               msg + (f" (labels dropped, not bare words or an open axis: {', '.join(dropped)})" if dropped else ""))
        if ok and join_epic:
            board_re = re.escape(ident) if ident else "[A-Z][A-Z0-9]*"
            m = re.search(rf"\b({board_re}-\d+)\b", msg)
            if not m:
                return record(i, {"op": "epic", "ref": title[:60]}, "error", f"created, but no ref in px output to join {epic}")
            ok, msg = px_write(repo, "epic", "add", epic, m.group(1))
            record(i, {"op": "epic", "ref": m.group(1)}, "ok" if ok else "error", msg)

    try:
        for i, w in enumerate(writes, 1):
            # Keep the lease fresh across a long apply, and stop the moment another driver owns the board.
            if i > 1 and not lease("refresh", lock, owner):
                entries.append({"op": "lease", "status": "error",
                                "detail": f"lease lost before write {i}: stopped, {len(writes) - i + 1} write(s) not applied"})
                break
            try:
                one(i, w)
            except Exception as e:  # one malformed or surprising write never aborts the pass or its receipt
                record(i, w if isinstance(w, dict) else {}, "error", f"{type(e).__name__}: {e}"[:240])
    finally:
        if writes:
            lease("release", lock, owner)

    roadmap = plan.get("roadmap")
    if roadmap not in (None, "") and not isinstance(roadmap, str):
        entries.append({"op": "roadmap", "status": "skip", "detail": "roadmap must be a string; kept the old one"})
        roadmap = ""
    roadmap = (roadmap or "").strip()
    if roadmap:
        lines = roadmap.splitlines()
        if len(lines) > ROADMAP_LINES:
            lines = lines[:ROADMAP_LINES - 1] + [f"(truncated to {ROADMAP_LINES} lines by the driver)"]
        ROADMAP.parent.mkdir(parents=True, exist_ok=True)
        ROADMAP.write_text("\n".join(lines).rstrip() + "\n")
        entries.append({"op": "roadmap", "status": "ok", "detail": str(ROADMAP)})

    stamp = f"{now():%Y%m%dT%H%M%SZ}"
    RECEIPTS.mkdir(parents=True, exist_ok=True)
    receipt = RECEIPTS / f"{stamp}.json"
    receipt.write_text(json.dumps({"stamp": stamp, "date": today(), "repo": str(repo), "owner": owner, "cap": cap,
                                   "note": str(plan.get("note") or "")[:300], "plan": plan, "results": entries}, indent=2) + "\n")
    for e in entries:
        print(f"{e['op']} {e.get('ref', '')}: {e['status']}: {e['detail']}".replace(" : ", ": "))
    if plan.get("note"):
        print(f"note: {str(plan['note'])[:300]}")
    print(f"receipt: {receipt}")
    return 0


def check(repo: Path) -> int:
    decl = load_declaration(repo)
    shown = {k: v for k, v in decl.items() if k != "raw"}
    print(json.dumps(shown, indent=2, sort_keys=True))
    return 1 if decl["error"] else 0


def main(argv: list[str]) -> int:
    cmds = [a for a in argv[1:] if a in ("--monitor", "--brief", "--apply", "--check")]
    if len(cmds) != 1:
        print(__doc__)
        return 2
    repo = find_repo()
    cmd = cmds[0]
    if cmd == "--monitor":
        return monitor(repo)
    if cmd == "--brief":
        return brief(repo)
    if cmd == "--check":
        return check(repo)
    rest = [a for i, a in enumerate(argv[1:], 1) if a not in ("--apply", "--repo") and argv[i - 1] != "--repo"]
    return apply(repo, rest[0] if rest else None)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
