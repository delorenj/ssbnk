#!/usr/bin/env python3
"""launch-pass: the repo-agnostic mode driver every PM role ships (develop / launch / polish).

An interval driver (the interval-driver skill). A script, not the model, holds the context. The mode
is DECLARED by the owner in a committed file at the repo root, `.launch.yaml`; this script never
guesses it and never edits it. Every reader normalises the mode: lowercase; `steady` is a legacy
alias that reads as `develop`; an unknown or broken declaration reads as `develop` and is reported.
`active` is `launch` or `polish`; `develop` (no pass runs) and `live` (in production: people can buy
it and are using it) are quiet: the snapshot is the single line `launch-mode: develop` or
`launch-mode: live`, so the unchanged snapshot costs 0 tokens.

  develop   the default: no file, `mode: develop`, or legacy `mode: steady`.
  launch    racing a finish line: one pass = launch-pass.prompt.md, plus the launch dashboard.
  polish    around-the-clock exploratory QA of the user experience: anything, however small, that can
            be improved or fixed gets a ticket (`[area:kind] ...` words inside the title, never a colon
            label; the driver adds the bare-word `polish` label). One pass = one QA cycle
            (polish-pass.prompt.md). The monitor carries a `qa-slot` line (the UTC minute floored to
            POLISH_SLOT_MINUTES, default 15) so every fire wakes the agent, and a
            `polish-metrics proposed=N implemented=M cycles=K` line fed by the ledger
            runtime/polish-metrics.json (the single source for the status line and `flume launch
            status`; a missing or broken ledger is no metrics, never an error). Polish creates default
            to the `polish` label, idempotency source `polish-pass`, key `polish:<hash>`; caps are 8
            creates and 20 writes (LAUNCH_PASS_MAX still overrides the write cap); every --apply is one
            cycle, even with zero writes; `implemented` refreshes from board state groups whenever the
            board was read; a new `declared:` archives the old ledger to polish-metrics.<declared>.json;
            the launch dashboard is launch-only (a polish plan's `dashboard` ops are refused).
  live      in production: no pass.

  launch-pass.py --monitor         stable snapshot (Hermes hashes it; unchanged = the agent never starts), ending with
                                   the repo's own .scripts/launch-pass.repo-monitor lines (off-board state), if any
  launch-pass.py --brief           the pass contract for the active mode (launch-pass.prompt.md or
                                   polish-pass.prompt.md, then the repo's own .scripts/launch-pass.repo.md,
                                   if any), the declaration, the rules pointer, the snapshot, the untagged
                                   comments waiting, the roadmap and the plan schema; polish also prints the
                                   metrics and the open polish ticket titles; launch also prints the launch
                                   dashboard section
  launch-pass.py --apply [PLAN]    apply the agent's plan (default runtime/launch-pass.json) under the
                                   board-driver lease, with a write cap and a receipt
  launch-pass.py --check           parse and print the declaration as JSON (debugging; exit 1 if broken)
  launch-pass.py --metrics         print the polish metrics ledger as JSON, with counts

Declaration (`.launch.yaml`, no status inside):
  mode: develop | launch | polish | live   (steady = legacy develop)    declared: YYYY-MM-DD
  source: "<doc + owner decision>"
  finish_line: "<what launched means>"    target_date: YYYY-MM-DD or empty
  contract: [<repo-relative paths>]       epic: <BOARD-n>
  scopes: [<child dirs>]         # optional, monorepo parent only: child directories whose px scope this PM also drives
  cut_line:                      # optional ranking hint; the board stays the truth
    launch_critical: [..]
    after_launch: [..]
  polish:                        # `mode: polish` only
    focus: [ux, physics]         # optional hint areas, never a limit: anything is ticketable
    qa: ["mise run qa:explore"]  # optional repo commands a QA cycle may run (exploratory harness, e2e, screenshots)
    wip: 4                       # Krebs WIP slots ("lanes") while polishing; default 4
    cadence: "*/15 * * * *"      # Candybar schedule of the pass; default every 15 minutes (launch is hourly)
    todo_depth: 8                # Todo is topped up to this many polish tickets; default 2 x wip
  live_since: YYYY-MM-DD         # `mode: live` only: the day it went live (launch history fields stay)
  live: {name, tagline, store_url, offer, platform, package, release, board, support, checkout,
         fulfilment}            # `mode: live` only: read by the Holocene Live hub, never by this pass

Allowed apply ops: comment, create, move, close, cancel, rank, link. Everything else is refused.
`rank` has no px verb (px cannot reorder a lane), so it degrades to a `launch rank N` comment and the
receipt says so. Moves are Backlog/Todo only: In Progress is Krebs' lane. px refuses an epic at either
end of a link or as a parent, so a `link` touching the declaration's epic, or a `create` whose `parent`
is that epic, becomes an epic membership (`px epic add EPIC REF`). Every ref (`ref`, `other`, `parent`) must
be on this board; a ticket carrying `agent:working` is never moved, closed or cancelled; `comment`, `close`
and `cancel` need a `text`; create labels are bare words or a fleet open axis (risk:, needs:, xp:). A write
whose fields have the wrong types is skipped, and the receipt is written whatever happens.

In launch mode the plan may also carry `"dashboard": [ops]` (docs/launch-dashboard.md). They apply after
the board writes through launch-dashboard.py, and every launch apply then re-renders and republishes the
launch dashboard. A refused dashboard op says why; a failed publish is reported in the receipt and never
undoes the board writes. In polish mode `dashboard` ops are refused with a receipt note.

stdlib only, python3. The script lives in <repo>/agents/hermes/<role>/.scripts/ and finds the repo by
walking up to `.project.json` (or `.git`); LAUNCH_REPO or --repo override. px runs with cwd = repo.
Env: LAUNCH_PASS_DATE (YYYY-MM-DD, tests), LAUNCH_PASS_NOW (ISO datetime, tests), LAUNCH_PASS_MAX (write
cap, default 12, 20 in polish), POLISH_SLOT_MINUTES (qa-slot width in minutes, default 15),
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
POLISH_PROMPT = HERE / "polish-pass.prompt.md"  # the QA-cycle contract; brief() picks it when the mode is polish
REPO_PROMPT = HERE / "launch-pass.repo.md"  # optional, repo-owned: the scaffold never writes, compares or removes it
REPO_MONITOR = HERE / "launch-pass.repo-monitor"  # optional, repo-owned executable: off-board state (gate receipts) for the snapshot
REPO_MONITOR_TIMEOUT_S = 60
REPO_MONITOR_MAX_LINES = 40
DASHBOARD = HERE / "launch-dashboard.py"
ROADMAP = RT / "launch-roadmap.md"
DEFAULT_PLAN = RT / "launch-pass.json"
RECEIPTS = RT / "launch-receipts"
METRICS = RT / "polish-metrics.json"  # the polish metrics ledger: the single source for the status line
OPEN = {"backlog", "unstarted", "started"}
ALLOWED_OPS = ("comment", "create", "move", "close", "cancel", "rank", "link")
LANES = ("Backlog", "Todo")
PRIORITIES = ("urgent", "high", "medium", "low", "none")
REF = re.compile(r"^([A-Z][A-Z0-9]*)-(\d+)$")
MAX_CREATES = 3
MAX_CREATES_POLISH = 8
ROADMAP_LINES = 40
MODES = ("develop", "launch", "polish", "live")  # develop is the default; launch races a finish line; polish is exploratory QA; live is in production
LEGACY_MODES = {"steady": "develop"}  # `steady` (pre-launch or internal) reads as develop everywhere
POLISH_LABEL = "polish"
POLISH_WIP_DEFAULT = 4
POLISH_CADENCE_DEFAULT = "*/15 * * * *"
WRITE_CAP_DEFAULT = 12
WRITE_CAP_POLISH = 20
WAITING_SHOWN = 40
STALE_HOURS = 48
AGENT_COMMENT = re.compile(r"^(\[[A-Za-z0-9 _:.-]+\]|krebs\b|hermes\b|momo\b)", re.I)
OWNER_BLOCKING = ("urgent", "high")
# board-taxonomy: a colon label is a closed, declared axis. A create may carry bare words and the fleet's
# open facet axes only; lifecycle:/agent: are automation's, repo: is px's, epic: would mint an epic.
OPEN_AXES = ("risk:", "needs:", "xp:")
STRING_FIELDS = ("ref", "other", "parent", "text", "title", "description", "key", "lane", "state", "priority", "scope")
NEEDS_TEXT = ("comment", "close", "cancel")


# --------------------------------------------------------------------------------------- time

def now() -> datetime:
    forced = os.environ.get("LAUNCH_PASS_NOW", "").strip()  # tests pin the clock to prove qa-slot rollover
    if forced:
        try:
            dt = parse_ts(forced)
            return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
        except ValueError:
            pass
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


def iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).isoformat(timespec="seconds")


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
    """The tiny YAML subset `.launch.yaml` uses: scalars, inline and block lists, maps nested by indent
    (the `live:` block of a `mode: live` declaration goes three deep)."""
    rows = []
    for raw in text.splitlines():
        line = _strip_comment(raw).rstrip()
        if line.strip():
            rows.append((len(line) - len(line.lstrip()), line.strip()))
    if rows and rows[0][0] != 0:
        raise ValueError(f"indented line with no parent: {rows[0][1]!r}")

    def block(i: int, indent: int):
        if rows[i][1].startswith("- "):
            items = []
            while i < len(rows) and rows[i][0] == indent and rows[i][1].startswith("- "):
                items.append(_scalar(rows[i][1][2:]))
                i += 1
            return items, i
        out: dict = {}
        while i < len(rows) and rows[i][0] == indent:
            body = rows[i][1]
            if ":" not in body or body.startswith("- "):
                raise ValueError(f"not a key: {body!r}")
            key, _, val = body.partition(":")
            key = key.strip()
            i += 1
            if val.strip():
                out[key] = _scalar(val)
            elif i < len(rows) and (rows[i][0] > indent or (rows[i][0] == indent and rows[i][1].startswith("- "))):
                out[key], i = block(i, rows[i][0])
            else:
                out[key] = None
        if i < len(rows) and rows[i][0] > indent:
            raise ValueError(f"indented line with no parent: {rows[i][1]!r}")
        return out, i

    if not rows:
        return {}
    parsed, _ = block(0, 0)
    return parsed if isinstance(parsed, dict) else {}


def _list(value) -> list[str]:
    if value in (None, ""):
        return []
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    return [str(value).strip()]


def _int(value, default: int, minimum: int = 1) -> int:
    try:
        n = int(str(value).strip())
    except (TypeError, ValueError):
        return default
    return n if n >= minimum else default


def load_declaration(repo: Path) -> dict:
    """Always returns a dict with `active` (bool), never raises: no file or a broken file is develop.
    `mode` is one of develop | launch | polish | live (`steady` is a legacy alias of develop, an unknown
    mode reads as develop and is reported in `error`); `active` is true for launch and polish."""
    path = repo / ".launch.yaml"
    decl = {"active": False, "path": str(path), "error": "", "raw": "", "mode": "develop"}
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
    mode = LEGACY_MODES.get(mode, mode)
    if mode not in MODES:
        if mode:
            decl["error"] = f"unknown mode {mode!r}"
        mode = "develop"
    cut = data.get("cut_line") if isinstance(data.get("cut_line"), dict) else {}
    polish = data.get("polish") if isinstance(data.get("polish"), dict) else {}
    wip = _int(polish.get("wip"), POLISH_WIP_DEFAULT)
    decl.update(
        mode=mode,
        active=mode in ("launch", "polish"),
        declared=str(data.get("declared") or ""),
        live_since=str(data.get("live_since") or ""),
        source=str(data.get("source") or ""),
        finish_line=str(data.get("finish_line") or ""),
        target_date=str(data.get("target_date") or ""),
        contract=_list(data.get("contract")),
        epic=str(data.get("epic") or "").strip(),
        scopes=_list(data.get("scopes")),
        launch_critical=_list(cut.get("launch_critical")),
        after_launch=_list(cut.get("after_launch")),
        focus=_list(polish.get("focus")),
        qa=_list(polish.get("qa")),
        wip=wip,
        cadence=str(polish.get("cadence") or "").strip() or POLISH_CADENCE_DEFAULT,
        todo_depth=_int(polish.get("todo_depth"), 2 * wip, minimum=0),
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
    t = None
    for attempt in range(4):  # Plane throttles a big board read: a refusal is retried, never a verdict
        try:
            t = px_json(repo, "task", "get", ref)["ticket"]
            break
        except Exception:
            if attempt == 3:
                raise
            time.sleep(1 + 2 * attempt)
    cs = sorted(t.get("comments") or [], key=lambda c: c.get("created_at", ""))
    mine = [c["created_at"] for c in cs if is_mine(c)]
    labels = t.get("label_names") or []
    updated = parse_ts(t["updated_at"])
    activity = updated
    # The PM's own comments bump updated_at; measure staleness from the last activity that was not ours.
    if cs and is_mine(cs[-1]) and updated - parse_ts(cs[-1]["created_at"]) <= timedelta(minutes=10):
        others = [c["created_at"] for c in cs if not is_mine(c)] or [t.get("created_at") or t["updated_at"]]
        activity = parse_ts(max(others))
    # The inbox starts at the PM's own last comment on the ticket, or, when it never spoke there, at the day
    # launch mode was declared: a board with months of worker comments is not a backlog of owner messages.
    floor = max(mine) if mine else (load_declaration(repo).get("declared") or "")[:10]
    waiting = [c for c in cs if not AGENT_COMMENT.match(comment_text(c)) and c["created_at"] > floor]
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
        # lifecycle:human: the owner took the ticket by hand. A hold like the rest, but the launch pass also
        # never plans or applies a write on it (comments included): only the owner removes the label.
        "human": HUMAN_LABEL in labels,
        "held": any(l in labels for l in ("lifecycle:needs-input", "lifecycle:blocked", "lifecycle:human", "agent:failed")),
        "activity": activity,
        "waiting": waiting,
        "comments": cs,
    }


def scope_dirs(repo: Path, decl: dict) -> dict[str, Path]:
    """Child directories (declaration `scopes:`) whose px scope this PM also drives, by declared name.

    A monorepo parent sees only its own `repo:*` scope from its own directory: px lists, writes and
    stamps by the nearest `.project.json`. Each declared child must sit inside the repo and carry one."""
    out: dict[str, Path] = {}
    root = repo.resolve()
    for name in decl.get("scopes") or []:
        p = (repo / name).resolve()
        if p != root and root in p.parents and (p / ".project.json").is_file():
            out[name] = p
    return out


def board_dirs(repo: Path, decl: dict | None) -> list[Path]:
    return [repo, *scope_dirs(repo, decl or {}).values()]


def ref_dirs(repo: Path, decl: dict | None) -> tuple[str, dict[str, Path], dict[str, str]]:
    """(board identifier, ref -> the directory whose scope owns it, ref -> state group) across every driven scope."""
    ident = ""
    where: dict[str, Path] = {}
    groups: dict[str, str] = {}
    for d in board_dirs(repo, decl):
        listing = px_json(d, "task", "list")
        ident = ident or str(listing.get("board") or "")
        for i in listing.get("issues", []):
            ref = f"{listing.get('board') or ident}-{i['sequence_id']}"
            where.setdefault(ref, d)
            groups.setdefault(ref, i.get("state_group") or "")
    return ident, where, groups


HUMAN_LABEL = "lifecycle:human"


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


# ------------------------------------------------------------------------------------- polish

def qa_slot() -> str:
    """The UTC minute floored to POLISH_SLOT_MINUTES (default 15). The slot changes on every cadence
    fire, so the monitor output changes and the Hermes job wakes the agent: polish runs around the clock."""
    width = _int(os.environ.get("POLISH_SLOT_MINUTES"), 15)
    n = now()
    return n.replace(minute=(n.minute // width) * width % 60, second=0, microsecond=0).strftime("%Y-%m-%dT%H:%MZ")


def empty_metrics(decl: dict) -> dict:
    return {"declared": decl.get("declared") or "", "cycles": 0, "proposed": [], "implemented": [], "updated_at": iso(now())}


def load_metrics(decl: dict) -> dict:
    """The polish metrics ledger (runtime/polish-metrics.json), the single source for the status line and
    `flume launch status`. A missing or broken file is an empty ledger, never an error. A ledger whose
    `declared` no longer matches the declaration's is archived to polish-metrics.<old declared>.json and a
    fresh ledger starts."""
    try:
        data = json.loads(METRICS.read_text())
        if not isinstance(data, dict):
            raise ValueError("not an object")
    except Exception:
        return empty_metrics(decl)
    old = str(data.get("declared") or "")
    if old != (decl.get("declared") or ""):
        try:
            METRICS.replace(METRICS.with_name(f"polish-metrics.{old or 'undeclared'}.json"))
        except OSError:
            pass
        return empty_metrics(decl)
    return {
        "declared": old,
        "cycles": data.get("cycles") if isinstance(data.get("cycles"), int) and not isinstance(data.get("cycles"), bool) else 0,
        "proposed": [p for p in data.get("proposed") or [] if isinstance(p, dict) and p.get("ref")],
        "implemented": [r for r in data.get("implemented") or [] if isinstance(r, str)],
        "updated_at": str(data.get("updated_at") or ""),
    }


def save_metrics(m: dict) -> None:
    m["updated_at"] = iso(now())
    METRICS.parent.mkdir(parents=True, exist_ok=True)
    tmp = METRICS.with_suffix(".tmp")
    tmp.write_text(json.dumps(m, indent=2) + "\n")
    tmp.replace(METRICS)


def refresh_implemented(m: dict, groups: dict[str, str]) -> bool:
    """implemented = the proposed refs now in the `completed` state group. True when the ledger changed."""
    have = set(m["implemented"])
    new = {p["ref"] for p in m["proposed"] if p.get("ref") in groups and groups[p["ref"]] == "completed"} - have
    if not new:
        return False
    m["implemented"] = m["implemented"] + sorted(new)
    return True


def metrics_line(m: dict) -> str:
    return f"polish-metrics proposed={len(m['proposed'])} implemented={len(m['implemented'])} cycles={m['cycles']}"


def snapshot_lines(decl: dict, rows: list[dict] | None) -> list[str]:
    if decl["mode"] == "polish":
        lines = [
            "launch-mode: polish",
            f"date {today()}",
            f"declaration {decl['sha']}",
            f"epic {decl.get('epic') or 'none'}",
            f"qa-slot {qa_slot()}",
            metrics_line(load_metrics(decl)),
        ]
    else:
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
        flags = ",".join(f for f, on in (("review", r["review"]), ("held", r["held"]), ("human", r["human"]), ("working", r["working"]), (POLISH_LABEL, POLISH_LABEL in r["labels"])) if on) or "-"
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


def repo_monitor_lines(repo: Path) -> list[str]:
    """The repo's own off-board state, so a change the board cannot show (a gate receipt, a store review state) wakes
    the pass. Optional and repo-owned: `.scripts/launch-pass.repo-monitor` prints stable lines (no timestamps). Each is
    prefixed `repo|`; a missing, failing or slow script is one fixed line, never an error."""
    if not REPO_MONITOR.is_file():
        return []
    try:
        out = subprocess.run([str(REPO_MONITOR)], cwd=repo, capture_output=True, text=True, timeout=REPO_MONITOR_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return ["repo|UNAVAILABLE"]
    if out.returncode != 0:
        return ["repo|UNAVAILABLE"]
    lines = [l.rstrip() for l in out.stdout.splitlines() if l.strip()]
    extra = len(lines) - REPO_MONITOR_MAX_LINES
    return ["repo|" + l for l in lines[:REPO_MONITOR_MAX_LINES]] + ([f"repo|{extra} more line(s) dropped"] if extra > 0 else [])


def snapshot(repo: Path) -> tuple[dict, list[str], list[dict] | None, str]:
    decl = load_declaration(repo)
    if not decl["active"]:
        return decl, [f"launch-mode: {decl['mode']}"], None, ""
    try:
        ident, _, groups = ref_dirs(repo, decl)
        refs = [r for r, g in groups.items() if g in OPEN]
        with ThreadPoolExecutor(8) as pool:
            rows = sorted(pool.map(lambda r: fetch_ticket(repo, r), refs), key=lambda r: r["seq"])
    except Exception:
        return decl, snapshot_lines(decl, None) + repo_monitor_lines(repo), None, ""
    if decl["mode"] == "polish":
        # The board was read: refresh implemented (proposed refs now completed) cheaply from the listing.
        m = load_metrics(decl)
        if refresh_implemented(m, groups):
            save_metrics(m)
    return decl, snapshot_lines(decl, rows) + repo_monitor_lines(repo), rows, ident


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
 "dashboard": [{"op": "upsert|check|uncheck|remove|requirement|marketplaces", "...": "ops and fields are in the dashboard section below; omit when nothing changed"}],
 "note": "one line"}"""


def dashboard_module():
    """launch-dashboard.py, loaded beside this file, or None when it is not shipped (an old scaffold)."""
    if not DASHBOARD.is_file():
        return None
    mod = sys.modules.get("launch_dashboard")
    if mod is None:
        import importlib.util
        sys.modules.setdefault("launch_pass", sys.modules[__name__])
        spec = importlib.util.spec_from_file_location("launch_dashboard", DASHBOARD)
        mod = importlib.util.module_from_spec(spec)
        sys.modules["launch_dashboard"] = mod
        spec.loader.exec_module(mod)
    return mod


def dashboard_brief(repo: Path, decl: dict, rows: list[dict] | None) -> str:
    try:
        mod = dashboard_module()
        return mod.brief_section(repo, decl, rows) if mod else "\n# Launch dashboard\n(launch-dashboard.py is missing: run flume remediate hermes.pm-scaffold)"
    except Exception as e:  # the dashboard never breaks the pass's brief
        return f"\n# Launch dashboard\n(unavailable: {type(e).__name__}: {e})"


def brief(repo: Path) -> int:
    decl, lines, rows, ident = snapshot(repo)
    mode = decl["mode"]
    polish = mode == "polish"
    if not decl["active"]:
        print(f"launch-mode: {mode}")
        if mode == "live":
            print("The product is live (.launch.yaml `mode: live`): there is no finish line to drive. Nothing to do: answer `quiet: live`.")
        else:
            print("No active mode declaration (.launch.yaml absent, or its mode is not `launch` or `polish`). Nothing to do: answer `quiet: develop`.")
        if decl.get("error"):
            print(f"(.launch.yaml problem: {decl['error']}. Treated as develop. Tell the owner in the pass note.)")
        return 0
    prompt = POLISH_PROMPT if polish else PROMPT
    print(_read(prompt).rstrip() or f"({prompt.name} is missing: run flume remediate hermes.pm-scaffold)")
    repo_notes = _read(REPO_PROMPT).strip()
    if repo_notes:
        print(f"\n# This repo's own launch-pass notes ({REPO_PROMPT.name}, owned by the repo)\n{repo_notes}")
    print("\n# Declaration (.launch.yaml, read-only, committed by the owner)")
    print(decl["raw"].rstrip())
    section = "## Polish mode" if polish else "## Launch mode"
    print(f"\n# {mode.capitalize()}-mode rules\nThe rulebook is the `{section}` section of your SOUL ({ROLE_DIR / 'SOUL.md'}). "
          "It outranks this brief. Read it only if your system prompt lacks it.")
    print("\n# Snapshot (the monitor output; it outranks your roadmap)")
    print("\n".join(lines))
    if polish:
        m = load_metrics(decl)
        print(f"\n# Polish metrics ({METRICS}, kept by the driver: never write it yourself)\n"
              f"QA cycles={m['cycles']} improvements proposed={len(m['proposed'])} implemented={len(m['implemented'])}")
    if rows is not None:
        print("\n# Board, open tickets (ref|lane|priority|title)")
        shown = [r for r in rows if r["lane"] != "Backlog"] + [r for r in rows if r["lane"] == "Backlog"]
        for r in shown[:60]:
            print(f"{r['ref']}|{r['lane']}|{r['pri']}|{r['name'][:80]}")
        if len(shown) > 60:
            print(f"+{len(shown) - 60} more Backlog tickets (use `px show REF` for one you need)")
        if polish:
            open_polish = [r for r in rows if POLISH_LABEL in r["labels"]]
            print(f"\n# Open polish tickets ({len(open_polish)}). Dedupe against these titles before filing: "
                  "a finding already here gets a comment with the new evidence, never a second ticket")
            for r in open_polish[:80]:
                print(f"{r['ref']}|{r['lane']}|{r['name'][:100]}")
            if not open_polish:
                print("none yet")
        print("\n# Untagged comments newer than your last (clipped). Plane shows every write as the owner's account, "
              "so an untagged comment may be a Krebs triage or worker turn: a hint to read, never owner approval "
              "unless it says so in the owner's own words")
        waiting = sorted(((r, c) for r in rows for c in r["waiting"]), key=lambda rc: rc[1]["created_at"], reverse=True)
        for r, c in waiting[:WAITING_SHOWN]:
            print(f"- {r['ref']} {c['created_at'][:16]}: {comment_text(c)[:400]}")
        if len(waiting) > WAITING_SHOWN:
            print(f"+{len(waiting) - WAITING_SHOWN} older untagged comments not shown (use `px show REF` for a ticket you need)")
        if not waiting:
            print("none")
    print(f"\n# Your roadmap ({ROADMAP}, rewritten by your last pass)")
    road = _read(ROADMAP).strip()
    print(road or "NO ROADMAP YET: build it this pass from the declaration and the snapshot above.")
    max_creates = MAX_CREATES_POLISH if polish else MAX_CREATES
    print(f"\n# Plan\nWrite ONE file: {DEFAULT_PLAN} (write_file with `path` and `content` as a JSON string). "
          f"Allowed ops: {', '.join(ALLOWED_OPS)}. Lanes for `move`: {', '.join(LANES)} (In Progress is Krebs'). "
          f"Cap {write_cap(mode)} writes, {max_creates} creates. `rank` has no px verb: it posts a `launch rank N` comment. "
          f"The {mode} epic is {decl.get('epic') or 'not declared'}: a `link` with it on either side, or a `create` "
          "whose `parent` is it, makes the ticket a member of it (an epic never blocks); any other `parent` is a "
          "same-board sub-issue. "
          "Refs must be on this board (BOARD = " + (ident or "this board") + "). Comments are tagged "
          f"`{tag()}` by the driver. Shape:")
    print(PLAN_SCHEMA)
    if polish:
        print(f"\nPolish creates: title `[area:kind] ...` (free-form lowercase words inside the title, e.g. "
              "`[ux:improvement] The location of the X element sometimes blocks Y`). The driver adds the bare-word "
              f"`{POLISH_LABEL}` label, idempotency source `polish-pass` and default key `polish:<hash>`. Creates land "
              f"in Backlog; each cycle also tops Todo up to todo_depth {decl['todo_depth']} with the highest-value "
              "polish tickets (a `move` per ticket).")
    kids = scope_dirs(repo, decl)
    if kids:
        print(f"\nChild scopes you also drive (the board lists and writes them by ref): {', '.join(kids)}. "
              "A `create` with `\"scope\": \"<one of them>\"` files the ticket from that child's directory "
              "(its `repo:*` label); without `scope` it lands in the repo's own scope. Join it to the epic with "
              "`parent` as usual. Never edit child code.")
    if polish:
        print("\n# Launch dashboard\nLaunch-only: it stays inert while polishing, and `dashboard` ops in a polish "
              "plan are refused.")
    else:
        print(dashboard_brief(repo, decl, rows))
    print(f"\nApply with: python3 {Path(__file__).resolve()} --apply")
    return 0


# --------------------------------------------------------------------------------------- apply

def write_cap(mode: str = "") -> int:
    default = WRITE_CAP_POLISH if mode == "polish" else WRITE_CAP_DEFAULT
    try:
        return max(1, int(os.environ.get("LAUNCH_PASS_MAX", str(default))))
    except ValueError:
        return default


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
        print(f"launch-mode: {decl['mode']}: apply refused, nothing written.")
        return 0
    polish = decl["mode"] == "polish"
    proj = project(repo)
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
    cap = write_cap(decl["mode"])
    max_creates = MAX_CREATES_POLISH if polish else MAX_CREATES
    metrics = load_metrics(decl) if polish else None
    proposed_now: list[dict] = []
    if metrics is not None:
        metrics["cycles"] += 1  # one apply in polish mode is one QA cycle, even with zero writes
    entries: list[dict] = []
    if len(writes) > cap:
        entries.append({"op": "cap", "status": "skip", "detail": f"{len(writes)} writes planned, applying the first {cap}"})
        writes = writes[:cap]

    tickets: dict[str, dict | None] = {}
    children = scope_dirs(repo, decl)
    try:
        where = ref_dirs(repo, decl)[1] if children else {}
    except Exception:
        where = {}  # board unreadable: every write falls back to the repo's own scope, px enforces the rest

    def at(ref: str) -> Path:
        """The directory px must run in for this ref: the child scope that owns it, else the repo."""
        return where.get(ref, repo)

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
        # The owner holds a lifecycle:human ticket by hand: no write of any op lands on it (as ref or `other`).
        if op != "create":
            for touched in (ref, w.get("other") or "") if op == "link" else (ref,):
                if not REF.match(touched):
                    continue
                th = get(touched)
                if th is not None and th["human"]:
                    return record(i, w, "skip", f"{touched} is held by the owner (lifecycle:human)")

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
            ok, msg = px_write(at(ref), "comment", ref, "-m", body)
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
            ok, msg = px_write(at(ref), *verb)
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
            ok, msg = px_write(at(ref), "link", "add", ref, other, *(["--blocks"] if w.get("blocks") is True else []))
            return record(i, w, "ok" if ok else "error", msg)
        # create. px parses its argv with node's strict parseArgs: a positional or a `-d` value that starts
        # with `-` (a markdown bullet) is a parse error, so the title loses leading dashes and every free-text
        # value rides in the `--flag=value` form.
        title = (w.get("title") or "").strip().lstrip("-").strip()[:200]
        if not title:
            return record(i, w, "skip", "create needs a title")
        if creates >= max_creates:
            return record(i, w, "skip", f"at most {max_creates} creates per pass")
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
        if polish and POLISH_LABEL not in labels:
            labels.append(POLISH_LABEL)  # every polish create carries the bare-word `polish` label
        key = (w.get("key") or "").strip().lstrip("-").strip() or \
            ("polish:" if polish else "launch:") + hashlib.sha1(title.lower().encode()).hexdigest()[:12]
        source = "polish-pass" if polish else "launch-pass"
        args = ["task", "create", title, "--state", state, "--idempotency-source", source, "--idempotency-key", key]
        if (w.get("description") or "").strip():
            args.append("--description=" + w["description"])
        if labels:
            args += ["-l", ",".join(labels)]
        if pri:
            args += ["--priority", pri]
        if parent and not join_epic:
            args += ["--parent", parent]
        scope = (w.get("scope") or "").strip()
        if scope and scope not in children:
            return record(i, {**w, "ref": title[:60]}, "skip", f"scope {scope!r} is not one of the declared child scopes {sorted(children)}")
        creates += 1
        ok, msg = px_write(children.get(scope, repo), *args)
        dropped = [l for l in wanted if l and l not in labels]
        record(i, {**w, "ref": title[:60]}, "ok" if ok else "error",
               msg + (f" (labels dropped, not bare words or an open axis: {', '.join(dropped)})" if dropped else ""))
        if ok and polish:
            board_re = re.escape(ident) if ident else "[A-Z][A-Z0-9]*"
            mref = re.search(rf"\b({board_re}-\d+)\b", msg)
            if mref:
                proposed_now.append({"ref": mref.group(1), "title": title, "at": iso(now())})
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

    dash_ops = plan.get("dashboard")
    if polish:
        # The launch dashboard is launch-only: never rendered or published while polishing.
        if dash_ops:
            entries.append({"op": "dashboard", "ref": "ops", "status": "skip",
                            "detail": "the launch dashboard is launch-only: dashboard ops are refused in polish mode"})
    else:
        try:
            mod = dashboard_module()
            if mod is not None:
                if dash_ops is not None and not isinstance(dash_ops, list):
                    entries.append({"op": "dashboard", "ref": "ops", "status": "refused", "detail": "`dashboard` must be a list of ops"})
                    dash_ops = None
                entries += mod.run_apply(repo, decl, dash_ops or [])
        except Exception as e:  # never fatal to the board writes above
            entries.append({"op": "dashboard", "ref": "apply", "status": "error", "detail": f"{type(e).__name__}: {e}"[:240]})

    if metrics is not None:
        known = {p.get("ref") for p in metrics["proposed"]}
        metrics["proposed"] += [p for p in proposed_now if p["ref"] not in known]
        try:
            refresh_implemented(metrics, ref_dirs(repo, decl)[2])
        except Exception:
            pass  # board unreadable: implemented refreshes on the next pass that reads it
        save_metrics(metrics)
        entries.append({"op": "metrics", "ref": "polish", "status": "ok",
                        "detail": f"QA cycle {metrics['cycles']}: proposed {len(metrics['proposed'])}, implemented {len(metrics['implemented'])} ({METRICS})"})

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


def metrics_cmd(repo: Path) -> int:
    decl = load_declaration(repo)
    m = load_metrics(decl)
    counts = {"proposed": len(m["proposed"]), "implemented": len(m["implemented"]), "cycles": m["cycles"]}
    print(json.dumps({**m, "counts": counts}, indent=2))
    return 0


def main(argv: list[str]) -> int:
    cmds = [a for a in argv[1:] if a in ("--monitor", "--brief", "--apply", "--check", "--metrics")]
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
    if cmd == "--metrics":
        return metrics_cmd(repo)
    rest = [a for i, a in enumerate(argv[1:], 1) if a not in ("--apply", "--repo") and argv[i - 1] != "--repo"]
    return apply(repo, rest[0] if rest else None)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
