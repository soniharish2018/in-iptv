#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh - scaffold the IPTV playlist builder into the current repo.
#
#   bash setup.sh          create/overwrite the files
#   bash setup.sh --push   also commit and push to the current branch
#
# Safe to re-run: it overwrites the four generated files and nothing else.
# ---------------------------------------------------------------------------
set -euo pipefail

PUSH=0
[[ "${1:-}" == "--push" ]] && PUSH=1

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "!! Not inside a git repository."
  echo "   cd into your clone of in-iptv first, then re-run."
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"
echo "repo root : $(pwd)"

mkdir -p .github/workflows

echo "writing  build.py"
cat > 'build.py' <<'__BUILD_PY__'
#!/usr/bin/env python3
"""
Build categorized + logo-enriched M3U playlists with a working EPG.

  1. fetch an upstream iptv-org playlist
  2. attach channel logos + categories from the iptv-org database
  3. match each channel to mitthu786/tvepg and rewrite tvg-id so the
     program guide actually binds in TiviMate / OTT Navigator
  4. write a master playlist, one playlist per category, a match report,
     and (optionally) a trimmed EPG containing only matched channels

Standard library only - no pip install needed.

Env vars (all optional):
  SOURCE_URL        upstream m3u      (default: iptv-org India playlist)
  OUTPUT_DIR        output directory  (default: playlists)
  MASTER_NAME       master file name  (default: all.m3u)
  BASE_URL          absolute base for index.html links / published EPG
  ENABLE_EPG        "false" to skip EPG matching entirely
  EPG_SOURCE_URL    XMLTV .xml/.xml.gz to match against
  EPG_XMLTV_URL     what to advertise as x-tvg-url (default: the source)
  EPG_PRIORITY      provider preference (default: jiotv,tataplay,zee5,sunnxt,sonyliv)
  EPG_FUZZY         "false" to disable fuzzy name matching
  PUBLISH_EPG       "true" to also write a trimmed epg.xml.gz (see README)
  OVERRIDES_FILE    csv of manual fixes  (default: overrides.csv)
"""

import csv
import difflib
import gzip
import io
import os
import re
import shutil
import sys
import urllib.request
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime, timezone


def env_flag(name, default=False):
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

SOURCE_URL = os.environ.get(
    "SOURCE_URL",
    "https://raw.githubusercontent.com/iptv-org/iptv/master/streams/in.m3u",
)
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "playlists")
MASTER_NAME = os.environ.get("MASTER_NAME", "all.m3u")
BASE_URL = os.environ.get("BASE_URL", "").rstrip("/")

ENABLE_EPG = env_flag("ENABLE_EPG", True)
EPG_SOURCE_URL = os.environ.get(
    "EPG_SOURCE_URL",
    "https://raw.githubusercontent.com/mitthu786/tvepg/main/epg.xml.gz",
)
EPG_PRIORITY = [
    p.strip().lower()
    for p in os.environ.get(
        "EPG_PRIORITY", "jiotv,tataplay,zee5,sunnxt,sonyliv"
    ).split(",")
    if p.strip()
]
EPG_FUZZY = env_flag("EPG_FUZZY", True)
PUBLISH_EPG = env_flag("PUBLISH_EPG", False)
OVERRIDES_FILE = os.environ.get("OVERRIDES_FILE", "overrides.csv")

if PUBLISH_EPG and BASE_URL:
    DEFAULT_XMLTV = f"{BASE_URL}/epg.xml.gz"
else:
    DEFAULT_XMLTV = EPG_SOURCE_URL
EPG_XMLTV_URL = os.environ.get("EPG_XMLTV_URL", "").strip() or DEFAULT_XMLTV

DB = "https://raw.githubusercontent.com/iptv-org/database/master/data"
CAT_DIR = os.path.join(OUTPUT_DIR, "categories")

CAT_EMOJI = {
    "Auto": "\U0001F697", "Animation": "\U0001F9F8", "Business": "\U0001F4BC",
    "Classic": "\U0001F39E\uFE0F", "Comedy": "\U0001F602", "Cooking": "\U0001F373",
    "Culture": "\U0001F3AD", "Documentary": "\U0001F3A5", "Education": "\U0001F393",
    "Entertainment": "\U0001F31F", "Family": "\U0001F46A", "General": "\U0001F4FA",
    "Interactive": "\U0001F579\uFE0F", "Kids": "\U0001F9D2",
    "Legislative": "\U0001F3DB\uFE0F", "Lifestyle": "\U0001F485",
    "Movies": "\U0001F3AC", "Music": "\U0001F3B5", "News": "\U0001F4F0",
    "Outdoor": "\U0001F3D5\uFE0F", "Public": "\U0001F4E1", "Relax": "\U0001F9D8",
    "Religious": "\U0001F64F", "Series": "\U0001F4FD\uFE0F", "Science": "\U0001F52C",
    "Shop": "\U0001F6D2", "Sports": "\u26BD", "Travel": "\u2708\uFE0F",
    "Weather": "\U0001F326\uFE0F", "XXX": "\U0001F51E", "Undefined": "\u2753",
}
FALLBACK_EMOJI = "\U0001F4CC"
FORMAT_RANK = {"PNG": 0, "SVG": 1, "WEBP": 2, "JPEG": 3, "GIF": 4, "APNG": 5}

ATTR_RE = re.compile(r'([A-Za-z0-9_-]+)="([^"]*)"')
RES_SUFFIX_RE = re.compile(r"\s*\((?:\d{3,4}p|SD|HD|FHD|4K)\)\s*$", re.I)
QUALITY_RE = re.compile(r"\b(hd|sd|fhd|uhd|4k|hevc)\b", re.I)
FILLER_WORDS = ("tv", "india", "channel", "live", "network", "official", "digital")


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def fetch(url, retries=3, binary=False):
    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "iptv-playlist-builder/2.0"}
            )
            with urllib.request.urlopen(req, timeout=120) as r:
                raw = r.read()
            return raw if binary else raw.decode("utf-8", errors="replace")
        except Exception as exc:  # noqa: BLE001
            last = exc
            print(f"  ! attempt {attempt}/{retries} failed for {url}: {exc}",
                  file=sys.stderr)
    raise SystemExit(f"Could not fetch {url}: {last}")


def fetch_csv(url):
    return list(csv.DictReader(io.StringIO(fetch(url))))


def label(cat):
    return f"{CAT_EMOJI.get(cat, FALLBACK_EMOJI)} {cat}"


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "other"


def norm(name):
    """'Colors HD (Hindi)' -> 'colors'"""
    s = re.sub(r"\([^)]*\)", " ", name).lower().replace("&", " and ")
    return re.sub(r"[^a-z0-9]", "", QUALITY_RE.sub(" ", s))


def match_keys(name):
    """Normalized key plus variants with trailing filler words removed."""
    out = {norm(name)}
    words = re.sub(
        r"[^a-z0-9 ]", "", QUALITY_RE.sub(" ", name.lower().replace("&", " and "))
    ).split()
    while words and words[-1] in FILLER_WORDS:
        words = words[:-1]
        if words:
            out.add("".join(words))
    return {k for k in out if k}


def provider_of(epg_id):
    if re.fullmatch(r"\d+", epg_id):
        return "jiotv"
    if re.fullmatch(r"ts\d+", epg_id):
        return "tataplay"
    if epg_id.startswith("sony"):
        return "sonyliv"
    if epg_id.startswith("0-9-"):
        return "zee5"
    if epg_id.startswith("sun"):
        return "sunnxt"
    return "other"


def provider_rank(epg_id):
    p = provider_of(epg_id)
    return EPG_PRIORITY.index(p) if p in EPG_PRIORITY else len(EPG_PRIORITY)


# --------------------------------------------------------------------------
# iptv-org database
# --------------------------------------------------------------------------

print(f"source      : {SOURCE_URL}")
print("fetching iptv-org database ...")

channels = {c["id"]: c for c in fetch_csv(f"{DB}/channels.csv")}
cat_names = {c["id"]: c["name"] for c in fetch_csv(f"{DB}/categories.csv")}

logos_by_channel = defaultdict(list)
for row in fetch_csv(f"{DB}/logos.csv"):
    logos_by_channel[row["channel"]].append(row)

print(f"  channels  : {len(channels)}")
print(f"  logos     : {sum(len(v) for v in logos_by_channel.values())}")


def pick_logo(channel_id, feed):
    candidates = logos_by_channel.get(channel_id, [])
    if not candidates:
        return ""
    in_use = [c for c in candidates if (c.get("in_use") or "").upper() == "TRUE"]
    candidates = in_use or candidates

    def score(c):
        try:
            width = int(c.get("width") or 0)
        except ValueError:
            width = 0
        feed_match = 0 if c.get("feed") == feed else (1 if not c.get("feed") else 2)
        fmt = FORMAT_RANK.get((c.get("format") or "").upper(), 9)
        size_penalty = 0 if 200 <= width <= 800 else (1 if width else 2)
        return (feed_match, fmt, size_penalty, -width)

    return sorted(candidates, key=score)[0]["url"]


# --------------------------------------------------------------------------
# EPG index
# --------------------------------------------------------------------------

epg_index = defaultdict(list)     # normalized name -> [epg_id, ...]
epg_names = {}                    # epg_id -> display name
overrides = {}                    # iptv-org channel id -> epg id
epg_xml = ""

if ENABLE_EPG:
    print(f"fetching EPG: {EPG_SOURCE_URL}")
    raw = fetch(EPG_SOURCE_URL, binary=True)
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    epg_xml = raw.decode("utf-8", errors="replace")
    del raw

    for cid, display in re.findall(
        r'<channel id="([^"]+)">\s*<display-name>([^<]*)</display-name>', epg_xml
    ):
        epg_names[cid] = display.strip()
        for key in match_keys(display):
            epg_index[key].append(cid)

    # highest-priority provider first within each name
    for key in epg_index:
        epg_index[key] = sorted(set(epg_index[key]), key=provider_rank)

    print(f"  epg channels: {len(epg_names)}")

    if os.path.exists(OVERRIDES_FILE):
        with open(OVERRIDES_FILE, newline="", encoding="utf-8") as f:
            usable = [ln for ln in f
                      if ln.strip() and not ln.lstrip().startswith("#")]
            for row in csv.DictReader(usable):
                src = (row.get("iptv_id") or "").strip()
                dst = (row.get("epg_id") or "").strip()
                if src and dst:
                    overrides[src] = dst
        unknown = [f"{k}->{v}" for k, v in overrides.items() if v not in epg_names]
        print(f"  overrides   : {len(overrides)}")
        if unknown:
            print(f"  ! override targets not present in this EPG: "
                  f"{', '.join(unknown)}", file=sys.stderr)

epg_key_list = list(epg_index)


def match_epg(channel_id, channel):
    """Return (epg_id, how)."""
    if not ENABLE_EPG:
        return "", "disabled"

    if channel_id in overrides:
        return overrides[channel_id], "override"
    if not channel:
        return "", "none"

    names = [channel["name"]] + [
        n for n in (channel.get("alt_names") or "").split(";") if n
    ]

    for name in names:                                   # tier 1: exact
        hits = epg_index.get(norm(name))
        if hits:
            return hits[0], "exact"

    for name in names:                                   # tier 2: filler-stripped
        for key in match_keys(name):
            hits = epg_index.get(key)
            if hits:
                return hits[0], "filler"

    if EPG_FUZZY:                                        # tier 3: fuzzy
        for name in names:
            key = norm(name)
            if len(key) < 6:
                continue
            close = difflib.get_close_matches(key, epg_key_list, n=1, cutoff=0.9)
            if close:
                return epg_index[close[0]][0], "fuzzy"

    return "", "none"


# --------------------------------------------------------------------------
# parse source playlist
# --------------------------------------------------------------------------

print("fetching source playlist ...")
lines = [ln.rstrip("\r\n") for ln in fetch(SOURCE_URL).splitlines()]

entries = []
i = 0
while i < len(lines):
    if not lines[i].startswith("#EXTINF"):
        i += 1
        continue

    meta, _, title = lines[i].partition(",")
    attrs = dict(ATTR_RE.findall(meta))
    extra, url = [], None

    j = i + 1
    while j < len(lines):
        nxt = lines[j].strip()
        if not nxt:
            j += 1
            continue
        if nxt.startswith("#"):
            extra.append(nxt)          # keep #EXTVLCOPT / #KODIPROP headers
            j += 1
        else:
            url = nxt
            j += 1
            break

    if url:
        entries.append(
            {"attrs": attrs, "title": title.strip(), "extra": extra, "url": url}
        )
    i = j

if not entries:
    raise SystemExit("No entries parsed from the source playlist - aborting.")

print(f"  streams   : {len(entries)}")


# --------------------------------------------------------------------------
# enrich
# --------------------------------------------------------------------------

buckets = defaultdict(list)
matched = with_logo = with_epg = 0
tier_counts = defaultdict(int)
used_epg_ids = set()
mapping_rows = []
seen_channel = set()

for e in entries:
    raw_id = e["attrs"].get("tvg-id", "")
    channel_id, _, feed = raw_id.partition("@")
    channel = channels.get(channel_id)

    if channel:
        matched += 1
        name = channel["name"]
        cats = [
            cat_names.get(c, c.title())
            for c in (channel.get("categories") or "").split(";")
            if c
        ]
    else:
        name = RES_SUFFIX_RE.sub("", e["title"]).strip()
        cats = []

    logo = pick_logo(channel_id, feed) if channel_id else ""
    if logo:
        with_logo += 1

    epg_id, how = match_epg(channel_id, channel)
    if epg_id:
        with_epg += 1
        used_epg_ids.add(epg_id)

    if channel_id and channel_id not in seen_channel:
        seen_channel.add(channel_id)
        tier_counts[how] += 1
        mapping_rows.append(
            (channel_id, name, epg_id, epg_names.get(epg_id, ""),
             provider_of(epg_id) if epg_id else "", how)
        )

    e["name"] = name
    e["logo"] = logo
    e["epg_id"] = epg_id
    e["iptv_id"] = raw_id
    e["cats"] = cats or ["Undefined"]
    for c in e["cats"]:
        buckets[c].append(e)

if ENABLE_EPG:
    print(f"  epg matched: {with_epg}/{len(entries)} streams, "
          f"{len(used_epg_ids)} distinct guide channels")


# --------------------------------------------------------------------------
# write playlists
# --------------------------------------------------------------------------

header = "#EXTM3U"
if ENABLE_EPG and EPG_XMLTV_URL:
    header = f'#EXTM3U x-tvg-url="{EPG_XMLTV_URL}" url-tvg="{EPG_XMLTV_URL}"'


def extinf(entry, group):
    # tvg-id must be the EPG's id for the guide to bind; the original
    # iptv-org id is kept alongside so the mapping stays debuggable
    tvg_id = entry["epg_id"] or entry["iptv_id"]
    attrs = [
        f'tvg-id="{tvg_id}"',
        f'tvg-name="{entry["name"]}"',
        f'tvg-logo="{entry["logo"]}"',
        f'group-title="{group}"',
    ]
    if entry["epg_id"] and entry["iptv_id"]:
        attrs.append(f'iptv-org-id="{entry["iptv_id"]}"')
    return f'#EXTINF:-1 {" ".join(attrs)},{entry["title"]}'


def write_playlist(path, items, group_of):
    with open(path, "w", encoding="utf-8") as f:
        f.write(header + "\n")
        for entry in items:
            f.write(extinf(entry, group_of(entry)) + "\n")
            for line in entry["extra"]:
                f.write(line + "\n")
            f.write(entry["url"] + "\n")


shutil.rmtree(OUTPUT_DIR, ignore_errors=True)
os.makedirs(CAT_DIR, exist_ok=True)

ordered = sorted(entries, key=lambda e: (e["cats"][0].lower(), e["name"].lower()))
write_playlist(
    os.path.join(OUTPUT_DIR, MASTER_NAME), ordered, lambda e: label(e["cats"][0])
)

summary = []
for cat in sorted(buckets, key=lambda c: (-len(buckets[c]), c.lower())):
    items = sorted(buckets[cat], key=lambda e: e["name"].lower())
    filename = f"{slug(cat)}.m3u"
    write_playlist(os.path.join(CAT_DIR, filename), items, lambda e, c=cat: label(c))
    summary.append((cat, filename, len(items),
                    sum(1 for e in items if e["logo"]),
                    sum(1 for e in items if e["epg_id"])))


# --------------------------------------------------------------------------
# epg mapping report + optional trimmed EPG
# --------------------------------------------------------------------------

if ENABLE_EPG:
    with open(os.path.join(OUTPUT_DIR, "epg-mapping.csv"), "w",
              newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["iptv_id", "channel_name", "epg_id", "epg_name",
                    "provider", "match"])
        w.writerows(sorted(mapping_rows, key=lambda r: r[1].lower()))

if ENABLE_EPG and PUBLISH_EPG:
    print("writing trimmed epg.xml.gz ...")
    out_path = os.path.join(OUTPUT_DIR, "epg.xml.gz")
    kept_ch = kept_pr = 0
    with gzip.open(out_path, "wt", encoding="utf-8", compresslevel=9) as out:
        out.write('<?xml version="1.0" encoding="utf-8"?>\n')
        out.write('<tv generator-info-name="iptv-playlist-builder" '
                  f'generator-info-url="{EPG_SOURCE_URL}">\n')
        for _, elem in ET.iterparse(io.StringIO(epg_xml), events=("end",)):
            if elem.tag == "channel":
                if elem.get("id") in used_epg_ids:
                    out.write(ET.tostring(elem, encoding="unicode") + "\n")
                    kept_ch += 1
                elem.clear()
            elif elem.tag == "programme":
                if elem.get("channel") in used_epg_ids:
                    out.write(ET.tostring(elem, encoding="unicode") + "\n")
                    kept_pr += 1
                elem.clear()
        out.write("</tv>\n")
    size_mb = os.path.getsize(out_path) / 1e6
    print(f"  kept {kept_ch} channels / {kept_pr} programmes ({size_mb:.1f} MB gz)")


# --------------------------------------------------------------------------
# index page + report
# --------------------------------------------------------------------------

built_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def pct(n):
    return n * 100 // len(entries)


def link(rel):
    return f"{BASE_URL}/{rel}" if BASE_URL else rel


rows = "\n".join(
    f'<tr><td>{label(cat)}</td><td class="n">{n}</td><td class="n">{ep}</td>'
    f'<td><a href="{link("categories/" + fn)}">{fn}</a></td></tr>'
    for cat, fn, n, _, ep in summary
)

html = f"""<!doctype html>
<html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>IPTV Playlists</title>
<style>
  :root {{ color-scheme: light dark; --fg:#111; --bg:#fff; --mut:#666; --line:#e5e5e5; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --fg:#e8e8e8; --bg:#111; --mut:#999; --line:#2a2a2a; }}
  }}
  body {{ font: 16px/1.5 system-ui, sans-serif; color: var(--fg); background: var(--bg);
         max-width: 780px; margin: 0 auto; padding: 2rem 1rem; }}
  table {{ width: 100%; border-collapse: collapse; margin-top: 1rem; }}
  td, th {{ padding: .5rem .4rem; border-bottom: 1px solid var(--line); text-align: left; }}
  .n {{ text-align: right; color: var(--mut); font-variant-numeric: tabular-nums; }}
  code {{ background: rgba(128,128,128,.15); padding: .15rem .35rem; border-radius: 4px;
          word-break: break-all; }}
  .mut {{ color: var(--mut); font-size: .9rem; }}
  a {{ color: inherit; }}
</style>
<h1>IPTV Playlists</h1>
<p class="mut">{len(entries)} streams &middot; {len(summary)} categories &middot;
logos {pct(with_logo)}% &middot; guide {pct(with_epg)}% &middot; rebuilt {built_at}</p>
<p>Master playlist: <a href="{link(MASTER_NAME)}"><code>{MASTER_NAME}</code></a></p>
<p class="mut">EPG: <code>{EPG_XMLTV_URL if ENABLE_EPG else "disabled"}</code>
&mdash; already embedded as <code>x-tvg-url</code>, no need to add it manually.</p>
<table><tr><th>Category</th><th class="n">Streams</th><th class="n">Guide</th>
<th>Playlist</th></tr>
{rows}
</table>
</html>
"""
with open(os.path.join(OUTPUT_DIR, "index.html"), "w", encoding="utf-8") as f:
    f.write(html)

report = [
    f"streams        : {len(entries)}",
    f"matched in db  : {matched}  (unmatched: {len(entries) - matched})",
    f"logo assigned  : {with_logo} ({pct(with_logo)}%)",
    f"epg assigned   : {with_epg} ({pct(with_epg)}%)  "
    f"[{', '.join(f'{k}={v}' for k, v in sorted(tier_counts.items()))}]",
    f"categories     : {len(summary)}",
    "",
    f"{'Category':<22}{'Streams':>8}{'Logo':>7}{'Guide':>7}",
]
report += [f"{label(c):<22}{n:>8}{lg:>7}{ep:>7}" for c, _, n, lg, ep in summary]
print("\n" + "\n".join(report))

gh_summary = os.environ.get("GITHUB_STEP_SUMMARY")
if gh_summary:
    with open(gh_summary, "a", encoding="utf-8") as f:
        f.write("## Playlist rebuilt\n\n```\n" + "\n".join(report) + "\n```\n")
__BUILD_PY__

echo "writing  overrides.csv"
cat > 'overrides.csv' <<'__OVERRIDES_CSV__'
# Manual EPG fixes. Anything here wins over automatic name matching.
# Find the ids you need in playlists/epg-mapping.csv (column: match = none
# means no guide was found; match = fuzzy is worth eyeballing).
#
#   iptv_id  = the iptv-org channel id, without the @FEED suffix
#   epg_id   = the id from mitthu786/tvepg
#              JioTV "144" | TataPlay "ts840" | Zee5 "0-9-zeetv"
#              SunNXT "sun9025" | SonyLIV "sony1000009246"
iptv_id,epg_id
__OVERRIDES_CSV__

echo "writing  README.md"
cat > 'README.md' <<'__README_MD__'
# IPTV Playlists — categorized, logos, and a working EPG

Rebuilds the [iptv-org](https://github.com/iptv-org/iptv) India playlist daily with:

- **channel logos** from the iptv-org database (~99% coverage)
- **category grouping** via `group-title`, with emoji prefixes (`📰 News`, `🎬 Movies`, …)
- **a working program guide** — channels are matched to
  [mitthu786/tvepg](https://github.com/mitthu786/tvepg) and `tvg-id` is rewritten
  to that guide's ids, so EPG binds automatically in TiviMate / OTT Navigator
  (~77% coverage)
- **one playlist per category** so you can load only what you want

No dependencies — standard-library Python, run by GitHub Actions.

---

## Setup (once)

1. Create a repo and push:

   ```
   build.py
   overrides.csv
   .github/workflows/update-playlists.yml
   README.md
   ```

2. **Settings → Actions → General → Workflow permissions** → **Read and write
   permissions** → Save. (Without this the workflow can't commit its output.)

3. **Actions** tab → *Update playlists* → **Run workflow**.

Takes about a minute. Refreshes daily at 02:00 UTC (07:30 IST).

---

## URLs to use in your player

Replace `USER/REPO` with your own:

**Everything, grouped by category**

```
https://raw.githubusercontent.com/USER/REPO/main/playlists/all.m3u
```

**A single category**

```
https://raw.githubusercontent.com/USER/REPO/main/playlists/categories/news.m3u
https://raw.githubusercontent.com/USER/REPO/main/playlists/categories/movies.m3u
https://raw.githubusercontent.com/USER/REPO/main/playlists/categories/sports.m3u
```

**You do not need to add the EPG URL separately** — it's embedded in the
playlist header as `x-tvg-url`, and most players pick it up automatically:

```
#EXTM3U x-tvg-url="https://raw.githubusercontent.com/mitthu786/tvepg/main/epg.xml.gz" url-tvg="..."
```

If your player asks for it anyway, paste that same URL into its EPG field.

### Faster delivery via jsDelivr (optional)

```
https://cdn.jsdelivr.net/gh/USER/REPO@main/playlists/all.m3u
```

### Browsable index via GitHub Pages (optional)

**Settings → Pages → Deploy from a branch → `main` / `/ (root)`**, then open
`https://USER.github.io/REPO/playlists/` for a table of categories with stream
and guide counts. For absolute links there, set `BASE_URL` in the workflow env:

```yaml
BASE_URL: https://USER.github.io/REPO/playlists
```

---

## How EPG matching works

iptv-org ids (`Colors.in@HD`) and tvepg ids (`144`) are unrelated, so channels
are matched **by name** in three tiers:

| Tier | What it does | Example |
| --- | --- | --- |
| `exact` | normalized name match — case, punctuation and HD/SD stripped | `Colors` → `Colors HD` (144) |
| `filler` | retries after dropping trailing noise words (`TV`, `India`, `Channel`…) | `Balle Balle` → `Balle Balle TV` |
| `fuzzy` | close-match on spelling variants (90% similarity) | `ABN Andhra Jyoti` → `ABN Andhra Jyothi` |

Matched entries get `tvg-id="144"`, and the original id is preserved as
`iptv-org-id="Colors.in@HD"` so nothing is lost.

When one name exists on several providers, `EPG_PRIORITY` decides (default
`jiotv,tataplay,zee5,sunnxt,sonyliv` — JioTV covers the most channels).

Every run writes **`playlists/epg-mapping.csv`**: one row per channel with the
guide id, provider, and which tier matched. Sort by `match` to review the
`fuzzy` rows or find the `none` ones.

### Fixing a wrong or missing match

Add a row to `overrides.csv` — it beats automatic matching:

```csv
iptv_id,epg_id
6TVTelugu.in,ts840
SomeChannel.in,144
```

`iptv_id` is the iptv-org id **without** the `@FEED` suffix. ID formats, per
tvepg: JioTV `144`, TataPlay `ts840`, Zee5 `0-9-zeetv`, SunNXT `sun9025`,
SonyLIV `sony1000009246`. The build warns if an override points at an id that
isn't in the guide.

### Self-hosting a trimmed EPG (optional)

The upstream guide is ~2 MB gzipped / 22 MB XML covering 1464 channels, but only
~500 are in this playlist. Set repository variable **`PUBLISH_EPG=true`**
(Settings → Secrets and variables → Actions → Variables) and the workflow builds
a trimmed guide (~0.8 MB) and attaches it to a `epg` release:

```
https://github.com/USER/REPO/releases/download/epg/epg.xml.gz
```

`x-tvg-url` switches to that automatically. It's uploaded as a **release asset,
not committed**, so daily rebuilds don't bloat git history. Worth turning on if
guide loading is slow on an Android TV box.

---

## Configuration

Set in the workflow's `env:` block:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SOURCE_URL` | iptv-org `streams/in.m3u` | Any iptv-org playlist URL |
| `OUTPUT_DIR` | `playlists` | Where files are written |
| `MASTER_NAME` | `all.m3u` | Master playlist filename |
| `BASE_URL` | *(empty)* | Absolute base for `index.html` links |
| `ENABLE_EPG` | `true` | `false` keeps the original iptv-org `tvg-id`s |
| `EPG_SOURCE_URL` | tvepg `epg.xml.gz` | Any XMLTV `.xml` or `.xml.gz` |
| `EPG_XMLTV_URL` | = source | What to advertise as `x-tvg-url` |
| `EPG_PRIORITY` | `jiotv,tataplay,zee5,sunnxt,sonyliv` | Provider preference |
| `EPG_FUZZY` | `true` | `false` for exact matching only |
| `PUBLISH_EPG` | `false` | Build + release a trimmed guide |
| `OVERRIDES_FILE` | `overrides.csv` | Manual match fixes |

### Other guides

tvepg also publishes single-provider files, useful if you only want one:

```yaml
EPG_SOURCE_URL: https://raw.githubusercontent.com/mitthu786/tvepg/main/jiotv/epg.xml.gz
EPG_PRIORITY: jiotv
```

### Other countries

```yaml
SOURCE_URL: https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us.m3u
ENABLE_EPG: "false"   # tvepg is India-only
```

For non-India playlists, iptv-org's own guides at
[iptv-org/epg](https://github.com/iptv-org/epg) are a better fit — and since
their ids already match iptv-org `tvg-id`s, just set `ENABLE_EPG: "false"` and
point `EPG_XMLTV_URL` at the right guide.

### Changing emojis or schedule

Emojis: edit `CAT_EMOJI` near the top of `build.py` (unknown categories get 📌;
set all values to `""` for plain text if your player renders boxes).
Schedule: edit the `cron:` line — every 6 hours is `0 */6 * * *`.

---

## Running locally

```bash
python build.py
ENABLE_EPG=false python build.py
SOURCE_URL=https://raw.githubusercontent.com/iptv-org/iptv/master/streams/gb.m3u python build.py
```

Python 3.9+. Nothing to install.

---

## Notes

- Streams come from iptv-org and go up and down constantly; the daily rebuild
  prunes dead links as upstream removes them.
- The ~23% of channels without guide data are mostly small regional channels
  genuinely absent from tvepg — not a matching failure.
- Channels with no category upstream land in `❓ Undefined`.
- `#EXTVLCOPT` / `#KODIPROP` lines (referrer, user-agent, DRM keys) are
  preserved, so streams needing custom headers keep working.
- tvepg is a third-party guide with no uptime guarantee. If a run fails on the
  EPG fetch, set `ENABLE_EPG: "false"` to keep playlists building.
__README_MD__

echo "writing  .github/workflows/update-playlists.yml"
cat > '.github/workflows/update-playlists.yml' <<'__WORKFLOW_YML__'
name: Update playlists

on:
  schedule:
    - cron: "0 2 * * *"      # daily at 02:00 UTC (07:30 IST)
  workflow_dispatch:
  push:
    branches: [main]
    paths:
      - build.py
      - overrides.csv
      - .github/workflows/update-playlists.yml

permissions:
  contents: write

concurrency:
  group: update-playlists
  cancel-in-progress: false

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 20

    env:
      SOURCE_URL: https://raw.githubusercontent.com/iptv-org/iptv/master/streams/in.m3u
      OUTPUT_DIR: playlists
      MASTER_NAME: all.m3u

      # EPG (mitthu786/tvepg)
      ENABLE_EPG: "true"
      EPG_SOURCE_URL: https://raw.githubusercontent.com/mitthu786/tvepg/main/epg.xml.gz
      EPG_PRIORITY: jiotv,tataplay,zee5,sunnxt,sonyliv
      EPG_FUZZY: "true"

      # Set repository variable PUBLISH_EPG=true (Settings -> Secrets and
      # variables -> Actions -> Variables) to also build a trimmed EPG and
      # attach it to a release. Release assets do not bloat git history.
      PUBLISH_EPG: ${{ vars.PUBLISH_EPG || 'false' }}
      EPG_XMLTV_URL: ${{ vars.PUBLISH_EPG == 'true' && format('https://github.com/{0}/releases/download/epg/epg.xml.gz', github.repository) || '' }}

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Build playlists
        run: python build.py

      - name: Publish trimmed EPG as a release asset
        if: env.PUBLISH_EPG == 'true'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release view epg >/dev/null 2>&1 || \
            gh release create epg --title "EPG" --notes "Trimmed XMLTV guide, rebuilt automatically."
          gh release upload epg playlists/epg.xml.gz --clobber
          rm -f playlists/epg.xml.gz    # keep the binary out of git history

      - name: Commit if changed
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add playlists
          if git diff --staged --quiet; then
            echo "No changes."
          else
            git commit -m "chore: rebuild playlists ($(date -u '+%Y-%m-%d %H:%M UTC'))"
            git push
          fi
__WORKFLOW_YML__


# --- sanity checks -----------------------------------------------------------
echo
if command -v python3 >/dev/null 2>&1; then
  python3 -m py_compile build.py && echo "ok  build.py compiles"
else
  echo "?   python3 not found - skipping syntax check"
fi

if command -v python3 >/dev/null 2>&1; then
  python3 - <<'CHECK' && echo "ok  workflow yaml parses"
import sys
try:
    import yaml
except ImportError:
    print("?   pyyaml not installed - skipping yaml check"); sys.exit(0)
yaml.safe_load(open(".github/workflows/update-playlists.yml"))
CHECK
fi

echo
echo "files created:"
printf '  %s\n' build.py overrides.csv README.md .github/workflows/update-playlists.yml

# --- optional push -----------------------------------------------------------
if [[ $PUSH -eq 1 ]]; then
  echo
  git add build.py overrides.csv README.md .github/workflows/update-playlists.yml
  if git diff --staged --quiet; then
    echo "nothing to commit - files already up to date"
  else
    git commit -m "Add playlist builder: logos, categories, EPG matching"
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    git push -u origin "$BRANCH"
    echo
    echo "pushed to $BRANCH"
  fi
  echo
  echo "Next:"
  echo "  1. Settings -> Actions -> General -> Workflow permissions -> Read and write"
  echo "  2. Actions tab -> 'Update playlists' -> Run workflow"
  echo "  3. gh workflow run update-playlists.yml   # or trigger it from the CLI"
else
  echo
  echo "Next:"
  echo "  git add -A && git commit -m 'Add playlist builder' && git push"
  echo "  (or re-run: bash setup.sh --push)"
fi
