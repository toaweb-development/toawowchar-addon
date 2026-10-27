#!/usr/bin/env python3
"""Writes the guide's leveling routes, toawowchar/Data/Routes.lua, from wowchar's route API.

    scripts/fetch-routes.py                       read https://wowchar.toaweb.com/api/routes and
                                                  /api/routes/<start> for every start, write the file
    scripts/fetch-routes.py --uimap FILE          also check every uiMapId against the client's own
                                                  UiMap table (a CSV with an ID column)
    --from-dir DIR                                read index.json and <start>.json from DIR instead of
                                                  the network (the tests use it)
    --out FILE                                    write somewhere else (default: the addon's Data/)
    --save-dir DIR                                also keep the raw answers there

The answers are checked strictly against the shape wowchar's app/server/api/routes/ returns (the
types in its app/shared/routes.ts). One thing out of place stops the script and writes nothing:
the guide must never load half a route. The file is the same bytes for the same answers (sorted,
fixed number format, no time of its own), so it is committed and a diff shows what changed.

Python 3.8 or newer, standard library only. The network is only read (GET); nothing is sent.
"""
import argparse
import csv
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = "https://wowchar.toaweb.com"
OUT = ROOT / "toawowchar" / "Data" / "Routes.lua"

# The eight starts the guide knows (Guide.lua picks one from the player's race). The API must
# serve exactly these: a new start needs a race mapping in the addon first.
STARTS = ("dwarf-gnome", "human", "nightelf", "orc-troll", "skyborne-a", "skyborne-h", "tauren", "undead")

# A step's kind, as the number the Lua file stores (Guide.lua has the same table).
KINDS = {"accept": 1, "objective": 2, "turnin": 3, "travel": 4, "grind": 5}

# Limits a sane route stays inside (wowchar's own limits are the same or tighter).
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_STEPS = 6000
MAX_QUESTS_PER_STEP = 25
MAX_TEXT = 4000
MAX_NAME = 200
MAX_ID = 2147483647
MAX_LEVEL = 60


class Bad(Exception):
    """The answer does not have the shape the script knows."""


def fetch(url):
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "toawowchar-addon fetch-routes"})
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310 (a fixed https address)
        if response.status != 200:
            raise Bad(f"{url} answered {response.status}")
        body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise Bad(f"{url} is larger than {MAX_RESPONSE_BYTES} bytes")
    return body


def load(source, name, save_dir):
    """The JSON of `name` (index or a start key), from the network or a directory."""
    file = "index.json" if name == "index" else f"{name}.json"
    if isinstance(source, Path):
        body = (source / file).read_bytes()
    else:
        url = f"{source}/api/routes" if name == "index" else f"{source}/api/routes/{name}"
        body = fetch(url)
    if save_dir:
        save_dir.mkdir(parents=True, exist_ok=True)
        (save_dir / file).write_bytes(body)
    return json.loads(body.decode("utf-8"))


# ---- the shape


def need(cond, what):
    if not cond:
        raise Bad(what)


def is_int(v, lo, hi):
    return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi


def is_num(v, lo, hi):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and lo <= v <= hi


def text(v, cap, what, nullable=False):
    if v is None and nullable:
        return None
    need(isinstance(v, str) and 0 < len(v) <= cap, f"{what} is not a text of 1 to {cap} characters")
    need(not re.search(r"[\x00-\x1f\x7f]", v), f"{what} has a control character")
    return v


def check_meta(meta, what):
    need(isinstance(meta, dict), f"{what} is not an object")
    key = meta.get("startKey")
    need(key in STARTS, f"{what}: startKey {key!r} is not one of {', '.join(STARTS)}")
    need(meta.get("faction") in ("A", "H"), f"{what}: faction is not A or H")
    need(isinstance(meta.get("confirmed"), bool), f"{what}: confirmed is not true or false")
    text(meta.get("questieVersion"), 100, f"{what}: questieVersion")
    need(isinstance(meta.get("generatedAt"), str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z", meta["generatedAt"]),
         f"{what}: generatedAt is not an ISO time in UTC")
    need(is_int(meta.get("stepCount"), 0, MAX_STEPS), f"{what}: stepCount is not 0 to {MAX_STEPS}")
    need(is_int(meta.get("levelEnd"), 1, MAX_LEVEL), f"{what}: levelEnd is not 1 to {MAX_LEVEL}")
    return key


def check_route(key, data, index_meta):
    what = f"/api/routes/{key}"
    need(isinstance(data, dict), f"{what} is not an object")
    meta = data.get("route")
    need(check_meta(meta, f"{what} route") == key, f"{what}: the route's startKey is not {key}")
    for field in ("faction", "confirmed", "questieVersion", "generatedAt", "stepCount", "levelEnd"):
        need(meta[field] == index_meta[field], f"{what}: {field} differs from /api/routes")

    zones = data.get("zones")
    need(isinstance(zones, list) and zones, f"{what}: zones is not a list")
    ui_map = {}
    zone_names = {}
    for z in zones:
        need(isinstance(z, dict) and is_int(z.get("id"), 1, MAX_ID), f"{what}: a zone has no id")
        need(is_int(z.get("uiMapId"), 1, MAX_ID), f"{what}: zone {z['id']} has no uiMapId")
        ui_map[z["id"]] = z["uiMapId"]
        zone_names[z["uiMapId"]] = text(z.get("name"), MAX_NAME, f"{what}: the name of zone {z['id']}")

    quests = data.get("quests")
    need(isinstance(quests, list), f"{what}: quests is not a list")
    quest_names = {}
    for q in quests:
        need(isinstance(q, dict) and is_int(q.get("id"), 1, MAX_ID), f"{what}: a quest has no id")
        quest_names[q["id"]] = text(q.get("name"), MAX_NAME, f"{what}: the name of quest {q['id']}")

    steps = data.get("steps")
    need(isinstance(steps, list) and len(steps) == meta["stepCount"], f"{what}: steps is not a list of stepCount steps")
    out = []
    for i, s in enumerate(steps, start=1):
        at = f"{what} step {i}"
        need(isinstance(s, dict) and s.get("n") == i, f"{at}: n is not {i}")
        need(s.get("kind") in KINDS, f"{at}: kind {s.get('kind')!r} is not known")
        need(s.get("mapId") in ui_map, f"{at}: mapId {s.get('mapId')!r} is not in zones")
        need(is_num(s.get("x"), 0, 100) and is_num(s.get("y"), 0, 100), f"{at}: x and y are not 0 to 100")
        ids = s.get("questIds")
        need(isinstance(ids, list) and len(ids) <= MAX_QUESTS_PER_STEP and all(is_int(q, 1, MAX_ID) for q in ids),
             f"{at}: questIds is not a list of quest ids")
        need(all(q in quest_names for q in ids), f"{at}: a quest id is not in quests")
        need(s["kind"] in ("travel", "grind") or ids, f"{at}: a {s['kind']} step has no quest")
        target = s.get("target")
        name = None
        if target is not None:
            need(isinstance(target, dict) and target.get("kind") in ("npc", "object"), f"{at}: target is not an npc or object")
            name = text(target.get("name"), MAX_NAME, f"{at}: the target's name")
        note = text(s.get("note"), MAX_TEXT, f"{at}: note", nullable=True)
        need(is_int(s.get("level"), 1, MAX_LEVEL), f"{at}: level is not 1 to {MAX_LEVEL}")
        out.append({"kind": KINDS[s["kind"]], "uiMapId": ui_map[s["mapId"]], "x": s["x"], "y": s["y"],
                    "quests": ids, "name": name, "level": s["level"], "text": note})
    return meta, out, quest_names, zone_names


def collect(source, save_dir):
    index = load(source, "index", save_dir)
    need(isinstance(index, dict) and isinstance(index.get("routes"), list), "/api/routes has no routes list")
    metas = {}
    for meta in index["routes"]:
        key = check_meta(meta, "/api/routes")
        need(key not in metas, f"/api/routes lists {key} twice")
        metas[key] = meta
    missing = [k for k in STARTS if k not in metas]
    need(not missing, f"/api/routes has no route for {', '.join(missing)} (click «Generate routes» in wowchar)")

    routes, quests, zones = {}, {}, {}
    for key in STARTS:
        meta, steps, quest_names, zone_names = check_route(key, load(source, key, save_dir), metas[key])
        routes[key] = (meta, steps)
        for qid, name in quest_names.items():
            need(quests.get(qid, name) == name, f"quest {qid} has two names")
            quests[qid] = name
        for mid, name in zone_names.items():
            need(zones.get(mid, name) == name, f"uiMap {mid} has two names")
            zones[mid] = name
    return routes, quests, zones


# ---- the Lua


def lua_string(value):
    """A Lua 5.1 string literal: quote and backslash escaped, bytes kept (UTF-8 as it is)."""
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def lua_number(value):
    """A whole number as an integer; a fraction with at most two decimals and no trailing zero."""
    if isinstance(value, int) or float(value).is_integer():
        return str(int(value))
    return f"{value:.2f}".rstrip("0").rstrip(".")


def render(routes, quests, zones):
    texts = sorted({t for _, steps in routes.values() for s in steps for t in (s["name"], s["text"]) if t})
    number = {t: i for i, t in enumerate(texts, start=1)}
    used_quests = sorted({q for _, steps in routes.values() for s in steps for q in s["quests"]})
    used_maps = sorted({s["uiMapId"] for _, steps in routes.values() for s in steps})

    lines = [
        "-- The guide's leveling routes, from wowchar (https://wowchar.toaweb.com/api/routes).",
        "-- Written by scripts/fetch-routes.py: do not edit, run the script again. The same answers",
        "-- give the same bytes. Lua 5.1, loaded by the TOC before Guide.lua.",
        "--",
        "-- A step is { kind, uiMapId, x, y, questIds, name, level, text }:",
        "--   kind     1 accept, 2 objective, 3 turn in, 4 travel, 5 grind",
        "--   uiMapId  the map the coordinates are on (UiMap ids of the Forever client)",
        "--   x, y     map percent, 0 to 100",
        "--   questIds the quests of the step (an empty list for travel and grind)",
        "--   name     the NPC or object to talk to: an index into T, 0 for none",
        "--   level    the level the route expects at this step (an estimate of wowchar's model)",
        "--   text     the objective, travel or grind note: an index into T, 0 for none",
        "local _, ns = ...",
        "",
        "-- The names and notes of the steps, sorted.",
        "local T = {",
    ]
    lines += [f"    {lua_string(t)}," for t in texts]
    lines += ["}", "", "-- The quests' names, by quest id.", "local Q = {"]
    lines += [f"    [{q}] = {lua_string(quests[q])}," for q in used_quests]
    lines += ["}", "", "-- The maps' names, by uiMapId.", "local Z = {"]
    lines += [f"    [{m}] = {lua_string(zones[m])}," for m in used_maps]
    lines += ["}", "", "local R = {}"]
    for key in STARTS:
        meta, steps = routes[key]
        lines += [
            "",
            f"R[{lua_string(key)}] = {{",
            f"    start = {lua_string(key)},",
            f"    faction = {lua_string(meta['faction'])},",
            f"    questie = {lua_string(meta['questieVersion'])},",
            f"    generated = {lua_string(meta['generatedAt'])},",
            f"    confirmed = {'true' if meta['confirmed'] else 'false'},",
            f"    levelEnd = {meta['levelEnd']},",
            "    steps = {",
        ]
        for s in steps:
            quest_list = "{" + ",".join(str(q) for q in s["quests"]) + "}"
            fields = [str(s["kind"]), str(s["uiMapId"]), lua_number(s["x"]), lua_number(s["y"]), quest_list,
                      str(number.get(s["name"], 0)), str(s["level"]), str(number.get(s["text"], 0))]
            lines.append("        {" + ",".join(fields) + "},")
        lines += ["    },", "}"]
    lines += ["", "ns.RouteData = { texts = T, quests = Q, zones = Z, routes = R }", ""]
    return "\n".join(lines), used_maps


def uimap_ids(path):
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        need("ID" in (reader.fieldnames or []), f"{path} has no ID column")
        return {int(row["ID"]) for row in reader if row["ID"].strip().isdigit()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--from-dir", type=Path, help="read the answers from this directory, not the network")
    parser.add_argument("--save-dir", type=Path, help="also keep the raw answers here")
    parser.add_argument("--out", type=Path, default=OUT, help="the Lua file to write")
    parser.add_argument("--uimap", type=Path, help="the client's UiMap table (CSV) to check the uiMapIds against")
    args = parser.parse_args(argv)

    try:
        routes, quests, zones = collect(args.from_dir or BASE, args.save_dir)
        lua, maps = render(routes, quests, zones)
    except (Bad, ValueError, OSError) as error:
        print(f"error: {error}; nothing was written", file=sys.stderr)
        return 1

    problems = 0
    if args.uimap:
        known = uimap_ids(args.uimap)
        absent = [m for m in maps if m not in known]
        for m in absent:
            print(f"uiMapId {m} ({zones[m]}) is not in {args.uimap.name}", file=sys.stderr)
        print(f"uiMapId check: {len(maps)} ids, {len(maps) - len(absent)} in {args.uimap.name}" + (f", {len(absent)} missing" if absent else ""))
        problems = len(absent)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(lua.encode("utf-8"))
    steps = sum(len(s) for _, s in routes.values())
    print(f"{args.out.name}: {len(routes)} routes, {steps} steps, {len(quests)} quests, {len(lua.encode('utf-8'))} bytes")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
