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

#### Zen / Firefox web apps (kiosk, Esc-close, fresh, no-sidebar)

Firefox-based site-specific apps (e.g. those created by **web-app-hub**) ignore
chromium-style flags, so for every `app.zen_browser.zen` shortcut `--fullscreen`
also does the following — so each app opens like a real fullscreen "game":

- **Esc closes the app** — a Firefox/Zen **kiosk ignores in-browser Esc
  bindings**, so closing is handled by the window manager instead. The tool
  installs `~/.local/bin/zen-kiosk-launch.sh` and re-points each Zen shortcut's
  `Exe` at it. The launcher binds `Esc → "close window"` in **GNOME** *only
  while the app is running* and restores the normal binding on exit — so Esc
  behaves normally everywhere else. (`Alt+F4` also works, always.) Needs
  **GNOME**; on other desktops the app still launches, just without Esc-close.
- **Its own profile** — apps that lack a `--profile=` (so they'd run in your
  *main* Zen profile) are given a **dedicated** one under web-app-hub, derived
  from their `--class`. This is what lets the per-app settings below apply
  without touching your everyday browser. _You'll sign in once_ in the new
  profile; after that the login sticks.
- **Per-app `user.js`** (written to each app's own profile):
  - **Fresh every launch** — no tab/session restore
    (`browser.startup.page=1`, `sessionstore.resume_from_crash=false`, …), and
    the piled-up `sessionstore`/`zen-sessions` files are cleared once.
  - **No browsing history** — `places.history.enabled=false`. **Passwords and
    login cookies are stored separately and kept**, so you stay logged in.
  - **Sidebar stays closed** — `zen.view.compact*`, `sidebar.visibility=hide-sidebar`,
    and `zen.view.sidebar-expanded.on-hover=false` so it doesn't pop out.

Every edited file is backed up (`.bak`), the `shortcuts.vdf` rewrite is guarded
by a round-trip check, and the whole thing is idempotent. The `user.js` step
**skips while Zen is running** (close Zen and rerun).

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
