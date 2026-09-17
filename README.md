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
