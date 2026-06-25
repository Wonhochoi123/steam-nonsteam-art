# steam-nonsteam-art

Auto-generate **Steam Big Picture / library artwork** for every *non-Steam*
shortcut — themed from each app's own logo. No SteamGridDB account, no API key,
no GUI. One command and your non-Steam apps look like real games.

It shines for **self-hosted and niche apps** (Immich, Audiobookshelf, Dockge,
Plex, …) that have little or no community art on SteamGridDB.

![showcase](examples/showcase.png)

*Auto-generated capsules — logos pulled by name, colours derived from each logo.*

## Why

Most artwork tools (Steam ROM Manager, BoilR, `steamgrid`, SteamGridDB Boop)
**download** community art from SteamGridDB. That's great for popular games, but
falls apart for the dashboard apps people actually pin to a couch HTPC — there
simply is no community art for "Dockge" or "Audiobookshelf".

`steam-nonsteam-art` takes the opposite approach: it **generates** clean,
visually consistent art from each app's official logo, so every shortcut gets a
full set — even the obscure ones.

## What it generates

For each non-Steam shortcut it writes 5 files into Steam's `grid/` folder, named
by the shortcut's (unsigned) app id:

| File | Size | Role |
|------|------|------|
| `<id>p.png` | 600×900 | portrait capsule (library poster) |
| `<id>.png` | 920×430 | wide capsule (Big Picture rows) |
| `<id>_hero.png` | 1920×620 | hero banner |
| `<id>_logo.png` | 1280×720 | transparent title logo |
| `<id>_icon.png` | 256×256 | icon |

## Requirements

- `bash`, `python3`, `curl`
- **ImageMagick** (`magick` or `convert`)
- A bold TrueType font (DejaVu/Liberation/FreeSans/Arial — autodetected)

Install deps on Debian/Ubuntu:

```bash
sudo apt install imagemagick fonts-dejavu-core python3 curl
```

## Usage

```bash
git clone https://github.com/Wonhochoi123/steam-nonsteam-art.git
cd steam-nonsteam-art
./steam-nonsteam-art.sh
```

That's it — it finds your Steam install(s), reads your non-Steam shortcuts, and
generates art for any that don't have it yet.

```bash
./steam-nonsteam-art.sh              # only fill in shortcuts missing art (idempotent)
./steam-nonsteam-art.sh --force      # regenerate everything
./steam-nonsteam-art.sh --fullscreen # also make browser shortcuts launch fullscreen
./steam-nonsteam-art.sh --help       # options
```

**Then fully restart Steam** (Steam → Exit, reopen) to load the new artwork.

### Fullscreen (optional)

Web-app shortcuts (Immich, a YouTube tab, any self-hosted dashboard) are
usually added as a browser **app window**. Pass `--fullscreen` and the tool
rewrites them to launch borderless-fullscreen kiosk mode, like a real game:

- **chromium / brave / chrome** (`--app=URL`) → `--kiosk URL`
- **Zen / Firefox** site-specific apps (`app.zen_browser.zen …`) → inserts
  `--kiosk`

```bash
# Quit Steam first (and close the browser), then:
./steam-nonsteam-art.sh --fullscreen
```

- **Off by default** — without the flag, launch options are never touched.
- Only converts shortcuts it can do **safely**; native apps are left alone.
- **Backs up `shortcuts.vdf`** before editing, and **refuses to run while Steam
  is open** (Steam would overwrite the change on exit).
- Idempotent — already-fullscreen shortcuts are reported and skipped.

#### Zen / Firefox web apps (Esc-to-quit + fresh session)

Firefox-based site-specific apps (e.g. those created by **web-app-hub**) ignore
chromium-style flags and keep their own per-app profile. For every Zen shortcut
that has its **own** `--profile=`, `--fullscreen` also makes the profile
kiosk-friendly:

- **Esc quits the app** — binds plain `Escape` → `cmd_quitApplication` in the
  profile's `zen-keyboard-shortcuts.json` (seeding it from an existing profile
  if needed). `Ctrl+Q` works too.
- **Each launch starts fresh** — disables tab/session restore in the profile's
  `user.js` (`browser.startup.page=1`, `sessionstore.resume_from_crash=false`,
  `warnOnQuit=false`, …) and clears the piled-up `sessionstore`/`zen-sessions`
  files once. **Cookies/logins are kept** — only old tabs are forgotten.

Every edited file is backed up (`.bak`), it's idempotent, and it **skips while
Zen is running**. Shortcuts that share the **default** Zen profile (no
`--profile=`) are **skipped on purpose**, so your everyday browser isn't
affected — give such apps their own profile if you want the same behaviour.

#### App quirks (config-based fullscreen)

Some apps ignore launch flags and store fullscreen in their **own config file**
(Electron apps, etc.). For those, `--fullscreen` flips the app's own setting:

| App | What it does |
|-----|--------------|
| **VacuumTube** (`rocks.shy.VacuumTube`) | sets `"fullscreen": true` in its `config.json` |

Each quirk backs up the file, is idempotent, and **skips while that app is
running** (it would overwrite the change on exit — close the app and rerun).

Adding another app is a few lines — write a `quirk_<name>` handler and register
it in `apply_app_quirks` (see the comments in the script).

### Environment overrides

| Var | Purpose |
|-----|---------|
| `FONT=/path/Bold.ttf` | force a specific font |
| `STEAM_ROOT=/path` | target one Steam root (skip autodetect) |
| `GRID=/path` | target one grid dir (handy for dry runs) |
| `ICON_BASE=<url>` | override the icon source |

Dry run into a throwaway folder:

```bash
FORCE=1 GRID=/tmp/test-grid ./steam-nonsteam-art.sh
```

## How it works

1. **Parse** each `shortcuts.vdf` (binary VDF) for `AppName` + `appid`, and
   convert the signed app id to the unsigned value Steam uses for grid filenames
   (`id % 2³²`).
2. **Fetch** a logo by slugified name from the
   [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons)
   repo (thousands of app logos), trying a few name variants.
3. **Theme** from the logo's dominant colour — a darkened glow background and a
   brightened accent for the title text.
4. **Fallback**: apps with no logo get a clean initials tile, coloured from a
   hash of the name.
5. **Generate** all five assets with ImageMagick and drop them in `grid/`.

## Supported Steam installs

Autodetected, including multiple accounts and multiple installs on one machine:

- Native (`~/.steam`, `~/.local/share/Steam`)
- Flatpak (`~/.var/app/com.valvesoftware.Steam/...`)
- Snap (`~/snap/steam/common/...`)
- macOS (`~/Library/Application Support/Steam`)

## Limitations

- It generates **branded template art**, not hand-made fan art. For popular
  games where you want gorgeous community pieces, use SteamGridDB-based tools.
- Multicolour logos can average to a muddy accent colour — override per app by
  dropping your own file into `grid/` with the same name and re-running Steam.
- This tool only handles **artwork**. The Steam overlay can't inject into
  sandboxed (snap/flatpak) apps regardless of art — that's a Steam limitation.

## Comparison

| Tool | Art source | Shortcuts | Headless |
|------|-----------|-----------|----------|
| **steam-nonsteam-art** | **generated from logo** | reads existing | ✅ |
| steamgrid | SteamGridDB | reads existing | ✅ |
| Steam ROM Manager | SteamGridDB | creates | ⚠️ GUI |
| BoilR | SteamGridDB | imports | ⚠️ GUI |
| SteamGridDB Boop | SteamGridDB | manual | ❌ GUI |

Complementary, not competing: use a SteamGridDB tool for AAA games, and this for
your self-hosted dashboard apps.

## Credits

Logos via [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons).

## License

[MIT](LICENSE)
