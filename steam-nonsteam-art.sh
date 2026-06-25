#!/usr/bin/env bash
#
# steam-nonsteam-art — auto-generate Steam Big Picture / library artwork for
# every non-Steam shortcut, themed from each app's own logo. No SteamGridDB
# account, no API key, no GUI. Great for self-hosted / niche apps that have
# no community art (Immich, Audiobookshelf, Dockge, ...).
#
# For each shortcut it writes 5 files into Steam's grid folder:
#   <id>p.png      600x900   portrait capsule (library poster)
#   <id>.png       920x430   wide capsule (Big Picture rows)
#   <id>_hero.png  1920x620  hero banner
#   <id>_logo.png  1280x720  transparent title logo
#   <id>_icon.png  256x256   icon
#
# Logos come from the homarr-labs/dashboard-icons repo (by slugified name);
# colours are derived from the logo's dominant colour; apps with no logo get
# a clean initials tile.
#
# Usage:
#   steam-nonsteam-art.sh [-f|--force] [-F|--fullscreen] [-h|--help]
#
# Options:
#   -f, --force        regenerate art even if it already exists
#   -F, --fullscreen   ALSO make shortcuts launch fullscreen:
#                        - Chromium/Brave shortcuts: --app=URL -> --kiosk URL
#                        - Zen/Firefox site-specific apps: insert --kiosk, and
#                          (per dedicated profile) bind Esc -> quit the app and
#                          stop tab/session restore so each launch starts fresh
#                        - known config-based apps (e.g. VacuumTube): flip the
#                          app's own fullscreen setting ("app quirks")
#                      Off by default; native apps without a known quirk are
#                      left untouched. Requires Steam (and the quirk app/browser)
#                      to be closed; backs up every file it edits.
#   -h, --help         show this help
#
# Env overrides:
#   FONT=/path/to/Bold.ttf     force a specific font
#   ICON_BASE=<url>            override the icon repo base
#   STEAM_ROOT=/path           force a single Steam root (skip autodetect)
#   GRID=/path                 force a single output dir (implies one target)
#   ALLOW_STEAM_RUNNING=1      skip the "is Steam closed?" guard (advanced)
#
# Deps: bash, python3, ImageMagick (magick or convert), curl, a bold TTF.
#
# License: MIT
set -uo pipefail

# ---------------------------------------------------------------------------
ICON_BASE="${ICON_BASE:-https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png}"
FORCE=0
DO_FS=0
for a in "$@"; do
  case "$a" in
    -f|--force)      FORCE=1 ;;
    -F|--fullscreen) DO_FS=1 ;;
    --no-fullscreen) DO_FS=0 ;;
    -h|--help)  awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "unknown arg: $a (try --help)"; exit 2 ;;
  esac
done

die(){ echo "error: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---- dependencies ----------------------------------------------------------
have python3 || die "python3 not found"
have curl    || die "curl not found"
IM="$(command -v magick || command -v convert || true)"
[ -n "$IM" ] || die "ImageMagick not found (need 'magick' or 'convert')"

# ---- font (skip variable fonts whose paths contain '[') --------------------
if [ -z "${FONT:-}" ]; then
  for f in \
    /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
    /usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf \
    /usr/share/fonts/truetype/freefont/FreeSansBold.ttf \
    /usr/share/fonts/TTF/DejaVuSans-Bold.ttf \
    /usr/share/fonts/dejavu/DejaVuSans-Bold.ttf \
    /Library/Fonts/Arial\ Bold.ttf \
    /System/Library/Fonts/Supplemental/Arial\ Bold.ttf \
    /System/Library/Fonts/Helvetica.ttc ; do
    [ -f "$f" ] && { FONT="$f"; break; }
  done
fi
if [ -z "${FONT:-}" ] && have fc-list; then
  FONT="$(fc-list 2>/dev/null | grep -iE 'Sans.*Bold|Bold.*Sans' | grep -v '\[' | head -1 | cut -d: -f1)"
fi
[ -n "${FONT:-}" ] && [ -f "$FONT" ] || die "no bold TTF font found; set FONT=/path/to/Bold.ttf"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---- discover Steam grid dirs (one per Steam account, all install types) ---
discover_grids(){
  local roots=()
  if [ -n "${STEAM_ROOT:-}" ]; then roots=("$STEAM_ROOT"); else
    roots=(
      "$HOME/.steam/steam"
      "$HOME/.steam/debian-installation"
      "$HOME/.steam/root"
      "$HOME/.local/share/Steam"
      "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"  # flatpak
      "$HOME/snap/steam/common/.local/share/Steam"                 # snap
      "$HOME/Library/Application Support/Steam"                     # macOS
    )
  fi
  local r f real
  for r in "${roots[@]}"; do
    [ -d "$r/userdata" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # canonicalize so symlinked roots (.steam/steam -> debian-installation) dedupe
      real="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$(dirname "$f")")"
      printf '%s\n' "$real/grid"
    done < <(find "$r/userdata" -maxdepth 3 -name shortcuts.vdf 2>/dev/null)
  done | sort -u
}

# ---- parse one shortcuts.vdf -> "unsigned_id<TAB>AppName" lines -------------
parse_vdf(){
python3 - "$1" <<'PY'
import sys,struct
d=open(sys.argv[1],'rb').read()
def cstr(i):
    j=d.index(b'\x00',i); return d[i:j].decode('utf-8','replace'),j+1
i=0; appid=None
while i < len(d):
    t=d[i]; i+=1
    if t in (0x00,0x08): continue
    if t==0x01:
        k,i=cstr(i); v,i=cstr(i)
        if k.lower()=='appname' and appid is not None:
            print(f"{appid}\t{v}"); appid=None
    elif t==0x02:
        k,i=cstr(i); val=struct.unpack('<i',d[i:i+4])[0]; i+=4
        if k.lower()=='appid': appid=val % (2**32)
    else:
        try: _,i=cstr(i)
        except: break
PY
}

slugify(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }

# hand-tuned slug overrides for names that don't map cleanly
slug_override(){
  case "$(slugify "$1")" in
    audiobookshelf|audiobook-shelf) echo audiobookshelf ;;
    *) echo "" ;;
  esac
}

# download a logo for $1 into $2; echo path on success
fetch_logo(){
  local name="$1" out="$2" cand full first ov
  full="$(slugify "$name")"; first="${full%%-*}"; ov="$(slug_override "$name")"
  for cand in "$ov" "$full" "$first" "${full%-htpc}" "${full#start-}" "${full#open-}"; do
    [ -n "$cand" ] || continue
    if curl -fsSL "$ICON_BASE/$cand.png" -o "$out" 2>/dev/null && [ -s "$out" ]; then
      printf '%s' "$out"; return 0
    fi
  done
  return 1
}

# initials tile when no logo exists; colour from a hash of the name
placeholder(){
  local name="$1" out="$2" letter hue
  letter="$(printf '%s' "$name" | grep -oE '[A-Za-z]' | head -1 | tr '[:lower:]' '[:upper:]')"; letter="${letter:-?}"
  hue=$(( $(printf '%s' "$name" | cksum | cut -d' ' -f1) % 360 ))
  "$IM" -size 512x512 xc:none \
    -fill "hsl($hue,55%,45%)" -draw "roundrectangle 50,50 462,462 70,70" \
    -gravity center -font "$FONT" -fill white -pointsize 300 -annotate +0+10 "$letter" \
    "$out"
  printf '%s' "$out"
}

# dominant colour of a logo -> "glow dark accent" hex triples
theme_from_logo(){
  local logo="$1" dom
  dom="$("$IM" "$logo" -trim +repage -alpha remove -resize '1x1!' -format '%[hex:p{0,0}]' info: 2>/dev/null)"
  [ -n "$dom" ] || dom="808080"
  python3 - "$dom" <<'PY'
import sys
h=sys.argv[1][:6].rjust(6,'0')
r,g,b=(int(h[i:i+2],16) for i in (0,2,4))
hx=lambda t:''.join('%02x'%max(0,min(255,int(c))) for c in t)
m=max(r,g,b,1); f=235/m
print(f"#{hx((r*.40,g*.40,b*.40))} #{hx((r*.09,g*.09,b*.09))} #{hx((r*f,g*f,b*f))}")
PY
}

# generate the 5 assets
gen_assets(){
  local grid="$1" id="$2" logo="$3" name="$4" glow="$5" dark="$6" accent="$7"
  "$IM" -size 600x900 radial-gradient:"$glow"-"$dark" \
    \( "$logo" -resize 340x340 \) -gravity center -geometry +0-70 -composite \
    -gravity south -font "$FONT" -fill "$accent" -pointsize 50 -annotate +0+80 "$name" \
    "$grid/${id}p.png"
  "$IM" -size 920x430 radial-gradient:"$glow"-"$dark" \
    \( "$logo" -resize 230x230 \) -gravity west -geometry +90+0 -composite \
    -gravity east -font "$FONT" -fill "$accent" -pointsize 60 -annotate +90+0 "$name" \
    "$grid/${id}.png"
  "$IM" -size 1920x620 radial-gradient:"$glow"-"$dark" \
    \( "$logo" -resize 300x300 \) -gravity center -geometry +0-30 -composite \
    "$grid/${id}_hero.png"
  "$IM" -size 1280x720 xc:none \
    \( "$logo" -resize 420x420 \) -gravity center -geometry +0-50 -composite \
    -gravity center -font "$FONT" -fill white -pointsize 92 -annotate +0+250 "$name" \
    "$grid/${id}_logo.png"
  "$IM" "$logo" -resize 256x256 -background none "$grid/${id}_icon.png"
}

process_grid(){
  local grid="$1" vdf
  vdf="$(dirname "$grid")/shortcuts.vdf"
  [ -f "$vdf" ] || return 0
  mkdir -p "$grid"
  echo "==> $vdf"
  local count=0
  while IFS=$'\t' read -r id name; do
    [ -n "$id" ] || continue
    if [ -f "$grid/${id}p.png" ] && [ "$FORCE" != "1" ]; then
      echo "    skip  $name ($id) — exists"; continue
    fi
    local logo="$WORK/$id.png" src
    if fetch_logo "$name" "$logo" >/dev/null; then src="logo"; else placeholder "$name" "$logo" >/dev/null; src="initials"; fi
    read -r glow dark accent < <(theme_from_logo "$logo")
    gen_assets "$grid" "$id" "$logo" "$name" "$glow" "$dark" "$accent"
    echo "    done  $name ($id) — $src"
    count=$((count+1))
  done < <(parse_vdf "$vdf")
  echo "    ($count generated)"
}

# ---- fullscreen: rewrite browser shortcuts to launch in kiosk -------------
steam_running(){ pgrep -x steam >/dev/null 2>&1 || pgrep -f steamwebhelper >/dev/null 2>&1; }

# Esc can't be handled inside a Firefox/Zen kiosk (it ignores custom Esc
# bindings), so for Zen web apps we close them from the window manager instead.
# This launcher binds Esc -> "close window" in GNOME *only while the app runs*,
# and restores the normal binding on exit — so Esc behaves normally everywhere
# else. steam-nonsteam-art rewrites Zen shortcuts to launch through it.
ZEN_WRAPPER="$HOME/.local/bin/zen-kiosk-launch.sh"
install_zen_wrapper(){
  mkdir -p "$(dirname "$ZEN_WRAPPER")"
  cat > "$ZEN_WRAPPER" <<'WRAP'
#!/usr/bin/env bash
# zen-kiosk-launch.sh — run a kiosk web app, and make Esc close its window
# (GNOME/Wayland) only while it is running. Managed by steam-nonsteam-art.sh.
set -u
SCHEMA=org.gnome.desktop.wm.keybindings
KEY=close
restore(){ [ -n "${OLD:-}" ] && gsettings set "$SCHEMA" "$KEY" "$OLD" 2>/dev/null; }
if command -v gsettings >/dev/null 2>&1; then
  OLD="$(gsettings get "$SCHEMA" "$KEY" 2>/dev/null)"
  case "$OLD" in
    *"'Escape'"*) : ;;   # already bound (e.g. a previous run); leave it, don't restore
    *)
      NEW="$(python3 - "$OLD" <<'PY'
import sys,ast
s=sys.argv[1].strip()
if s.startswith('@as '): s=s[4:].strip()
try: lst=ast.literal_eval(s) if s else []
except Exception: lst=[]
if not isinstance(lst,list): lst=[]
if 'Escape' not in lst: lst.append('Escape')
print('['+', '.join("'%s'"%x for x in lst)+']')
PY
)"
      gsettings set "$SCHEMA" "$KEY" "$NEW" 2>/dev/null && trap restore EXIT INT TERM
      ;;
  esac
fi
"$@"   # run the app in the foreground; trap restores the binding when it exits
WRAP
  chmod +x "$ZEN_WRAPPER"
}

# Edit one shortcuts.vdf in place:
#   * chromium/brave  "--app=URL"            -> "--kiosk" "URL"
#   * Zen/Firefox     app.zen_browser.zen …  -> insert "--kiosk", and (if a
#                     wrapper path is given) route Exe through the wrapper so
#                     Esc closes the app.
# Uses a full structured parse + reserialize of the binary VDF, guarded by a
# round-trip check (refuses to write unless re-encoding reproduces the original
# byte-for-byte). Backs up first.
apply_fullscreen(){
  local vdf="$1"
  [ -f "$vdf" ] || return 0
  cp "$vdf" "$vdf.bak.$(date +%Y%m%d-%H%M%S)"
  python3 - "$vdf" "${2:-}" <<'PY'
import sys, shutil, time, re, os
p=sys.argv[1]; wrapper=(sys.argv[2] if len(sys.argv)>2 else '').encode()
d=open(p,'rb').read()

pos=0
def rd():
    global pos
    j=d.index(0,pos); s=d[pos:j]; pos=j+1; return s
def parse():
    global pos
    items=[]
    while True:
        t=d[pos]; pos+=1
        if t==0x08: return items
        k=rd()
        if   t==0x00: items.append([0x00,k,parse()])
        elif t==0x01: items.append([0x01,k,rd()])
        elif t==0x02: v=d[pos:pos+4]; pos+=4; items.append([0x02,k,v])
        else: sys.exit("vdf: unsupported token 0x%02x at %d"%(t,pos-1))
top=parse()
def ser(items):
    o=bytearray()
    for t,k,v in items:
        o.append(t); o+=k+b'\x00'
        if   t==0x00: o+=ser(v); o.append(0x08)
        elif t==0x01: o+=v+b'\x00'
        elif t==0x02: o+=v
    return o
if bytes(ser(top))+b'\x08' != d:
    sys.exit("vdf round-trip mismatch — refusing to edit (please report)")

def field(entry,key):
    for it in entry:
        if it[0]==0x01 and it[1].lower()==key: return it
    return None
def kiosk(val):
    low=val.lower()
    if b'--kiosk' in low or b'--start-fullscreen' in low: return val,False
    if b'--app=' in val: return val.replace(b'"--app=', b'"--kiosk" "'),True
    if b'app.zen_browser.zen' in low:
        for sch in (b'"http', b'"about:', b'"file:'):
            k=val.find(sch)
            if k!=-1: return val[:k]+b'"--kiosk" '+val[k:],True
    return val,False

shortcuts=next((v for t,k,v in top if t==0x00 and k.lower()==b'shortcuts'),[])
entries=[v for t,k,v in shortcuts if t==0x00]

# Where to put dedicated profiles for Zen apps that don't have one: reuse the
# folder an existing --profile= lives in, else the web-app-hub default.
home=os.path.expanduser('~').encode()
prof_base=home+b'/.var/app/app.zen_browser.zen/data/web-app-hub/profiles'
for e in entries:
    lo=field(e,b'launchoptions')
    if lo:
        m=re.search(rb'--profile=([^"]+)', lo[2])
        if m: prof_base=m.group(1).rsplit(b'/',1)[0]; break

def inject_profile(val):
    # give a Zen app its own profile (so per-app prefs don't touch the main
    # browser). Profile id = --class/--name minus the web-app-hub "wah-" prefix.
    if b'--profile=' in val.lower(): return val,False
    m=re.search(rb'--(?:class|name)=([^"\s]+)', val)
    if not m: return val,False
    pid=m.group(1)
    if pid.startswith(b'wah-'): pid=pid[4:]
    path=prof_base+b'/'+pid
    try: os.makedirs(path, exist_ok=True)
    except OSError: return val,False
    tok=b'"--profile=' + path + b'" '
    at=val.find(b'"--no-remote"')
    if at==-1:
        for sch in (b'"http', b'"about:', b'"file:'):
            k=val.find(sch)
            if k!=-1: at=k; break
    if at==-1: return val,False
    return val[:at]+tok+val[at:],True

report=[]
for e in entries:
    lo=field(e,b'launchoptions'); ex=field(e,b'exe'); nm=field(e,b'appname')
    if not lo: continue
    name=nm[2].decode('utf-8','replace') if nm else '?'
    lo[2],ch=kiosk(lo[2])
    if ch: report.append(('kiosk',name))
    # give shared-profile Zen apps their own profile
    if b'app.zen_browser.zen' in lo[2].lower():
        lo[2],ch=inject_profile(lo[2])
        if ch: report.append(('profile',name))
    # wrap Zen apps so Esc closes them (handled by the window manager)
    if wrapper and ex and b'app.zen_browser.zen' in lo[2].lower():
        if wrapper.split(b'/')[-1] not in ex[2]:
            lo[2]=ex[2]+b' '+lo[2]          # old Exe becomes argv[0..] for the wrapper
            ex[2]=b'"'+wrapper+b'"'
            report.append(('esc',name))

out=bytes(ser(top))+b'\x08'
shutil.copy(p,p+'.bak.'+time.strftime('%Y%m%d-%H%M%S'))
open(p,'wb').write(out)
labels={'kiosk':'kiosk    ','profile':'own-prof ','esc':'esc-close'}
for kind,n in report:
    print(labels.get(kind,kind)+f"  {n}")
if not report: print("(no shortcuts needed fullscreen/esc changes)")
PY
}

# ---- app quirks: apps that ignore launch flags and store fullscreen in their
# own config file. Each handler is keyed off a signature found in shortcuts.vdf.
# To add an app: write a quirk_<name> function (idempotent, backs up, skips if
# the app is running), then register it in apply_app_quirks below.

# set a top-level boolean key to true in a JSON config, in place, idempotently
json_set_true(){
  local cfg="$1" key="$2" label="$3" procmatch="$4"
  [ -f "$cfg" ] || { echo "$label: config not found, skipped ($cfg)"; return; }
  if pgrep -fi "$procmatch" >/dev/null 2>&1; then
    echo "$label: RUNNING — close it and rerun (it would overwrite the change on exit)"; return
  fi
  python3 - "$cfg" "$key" "$label" <<'PY'
import json,sys,shutil
p,key,label=sys.argv[1],sys.argv[2],sys.argv[3]
try: c=json.load(open(p))
except Exception as e: print(f"{label}: cannot parse config ({e})"); sys.exit(0)
if c.get(key) is True: print(f"{label}: already fullscreen"); sys.exit(0)
shutil.copy(p,p+'.bak'); c[key]=True
json.dump(c,open(p,'w'),indent=4)
print(f"{label}: fullscreen -> true ({p.split('/')[-1]})")
PY
}

quirk_vacuumtube(){
  local cfg="$HOME/.var/app/rocks.shy.VacuumTube/config/VacuumTube/config.json"  # flatpak
  [ -f "$cfg" ] || cfg="$HOME/.config/VacuumTube/config.json"                    # native fallback
  json_set_true "$cfg" "fullscreen" "VacuumTube" "vacuumtube"
}

# Zen/Firefox site-specific apps (e.g. created by web-app-hub): for every shortcut
# that launches app.zen_browser.zen with its own --profile=, make the profile
# kiosk-friendly: bind plain Esc -> quit the app, and disable tab/session restore
# so each launch opens just the URL (no piling-up of old tabs). Cookies/logins are
# kept. Shortcuts that share the default Zen profile (no --profile=) are skipped so
# the main browser is left untouched. Backs up every file it edits.
quirk_zen_webapps(){
  local vdf="$1"
  grep -aq 'app.zen_browser.zen' "$vdf" 2>/dev/null || return 0
  if pgrep -fi 'zen[-_]?browser|/zen\b|zen-bin' >/dev/null 2>&1; then
    echo "Zen web apps: RUNNING — close Zen and rerun (it would overwrite the change on exit)"; return
  fi
  python3 - "$vdf" "$HOME" <<'PY'
import sys, os, re, json, glob, shutil, time
vdf, home = sys.argv[1], sys.argv[2]
d = open(vdf, 'rb').read()

# --- pull every LaunchOptions string out of the binary shortcuts.vdf ----------
launch = []
i = 0
while i < len(d):
    t = d[i]; i += 1
    if t == 0x01:                       # string field: key\0 value\0
        j = d.index(0, i); key = d[i:j]; i = j + 1
        j = d.index(0, i); val = d[i:j]; i = j + 1
        if key.lower() == b'launchoptions':
            launch.append(val.decode('utf-8', 'replace'))
    elif t == 0x02:                     # int field: key\0 + 4 bytes
        j = d.index(0, i); i = j + 1 + 4
    elif t == 0x00:                     # nested map: name\0
        j = d.index(0, i); i = j + 1
    elif t == 0x08:                     # end of map
        pass
    else:
        break

profiles, shared = [], []
for lo in launch:
    if 'app.zen_browser.zen' not in lo: continue
    m = re.search(r'--profile=([^"]+)', lo)
    name = (re.search(r'--name=([^"\s]+)', lo) or [None, lo[:40]])[1]
    if m: profiles.append((name, m.group(1)))
    else: shared.append(name)

if not profiles and not shared:
    print("(no Zen web-app shortcuts found)"); sys.exit(0)

PREFS = [
    'user_pref("zen.welcome-screen.seen", true);',                 # no welcome tour in fresh profiles
    # fresh launch: never restore the previous tabs/windows (stops the pile-up)
    'user_pref("browser.startup.page", 1);',                       # 1=home, not 3=restore session
    'user_pref("browser.sessionstore.resume_from_crash", false);', # no "restore?" after a hard kill
    'user_pref("browser.sessionstore.max_resumed_crashes", 0);',
    'user_pref("browser.sessionstore.resume_session_once", false);',
    'user_pref("browser.warnOnQuit", false);',                     # Esc must close without a prompt
    'user_pref("browser.tabs.warnOnClose", false);',
    # no browsing history (logins/passwords/cookies are stored separately, kept)
    'user_pref("places.history.enabled", false);',
    # keep the Zen sidebar collapsed and stop it popping out on hover
    'user_pref("zen.view.compact", true);',
    'user_pref("zen.view.compact.enable-at-startup", true);',
    'user_pref("zen.view.sidebar-expanded", false);',
    'user_pref("zen.view.sidebar-expanded.on-hover", false);',
    'user_pref("sidebar.visibility", "hide-sidebar");',
]
SESSION_GLOBS = ['sessionstore.jsonlz4', 'sessionstore-backups/*', 'recovery.jsonlz4',
                 'sessionCheckpoints.json', 'zen-sessions.jsonlz4', 'zen-sessions-backup/*']

def backup(p):
    if os.path.exists(p) and not os.path.exists(p + '.bak'):
        shutil.copy2(p, p + '.bak')

def ensure_prefs(prof):
    ujs = os.path.join(prof, 'user.js')
    cur = open(ujs).read() if os.path.isfile(ujs) else ''
    backup(ujs)
    add = [p for p in PREFS if p.split(',')[0] not in cur]  # keyed on the pref name
    if add:
        with open(ujs, 'a') as f:
            if cur and not cur.endswith('\n'): f.write('\n')
            f.write('\n'.join(add) + '\n')
    return len(add)

def drop_dead_esc(prof):
    # earlier versions tried to bind Esc inside Zen; kiosk ignores it, so the
    # window manager handles Esc now (see zen-kiosk-launch.sh). Remove the dead
    # entry if a previous run left one.
    f = os.path.join(prof, 'zen-keyboard-shortcuts.json')
    if not os.path.isfile(f): return
    try: data = json.load(open(f))
    except Exception: return
    sc = data.get('shortcuts')
    if not isinstance(sc, list): return
    new = [e for e in sc if not (isinstance(e, dict) and e.get('id') == 'key_quitAppOnEscape')]
    if len(new) != len(sc):
        data['shortcuts'] = new
        json.dump(data, open(f, 'w'), indent=2)

def clear_sessions(prof):
    n = 0
    for g in SESSION_GLOBS:
        for p in glob.glob(os.path.join(prof, g)):
            try:
                os.replace(p, p + '.bak-%s' % time.strftime('%Y%m%d-%H%M%S')); n += 1
            except OSError: pass
    return n

for name, prof in profiles:
    if not os.path.isdir(prof):
        print(f"{name}: profile dir missing, skipped ({prof})"); continue
    np = ensure_prefs(prof)
    drop_dead_esc(prof)
    cs = clear_sessions(prof)
    print(f"{name}: fresh-session prefs (+{np}); cleared {cs} old session file(s)")

for name in shared:
    print(f"{name}: shares the default Zen profile — fresh-session skipped (Esc-close still works via the launcher)")
PY
}

# dispatch quirks for whichever known apps are present in this shortcuts.vdf
apply_app_quirks(){
  local vdf="$1"
  grep -aq 'rocks.shy.VacuumTube' "$vdf" 2>/dev/null && quirk_vacuumtube
  grep -aq 'app.zen_browser.zen' "$vdf" 2>/dev/null && quirk_zen_webapps "$vdf"
  # add more apps here, e.g.:
  #   grep -aq '<signature>' "$vdf" && quirk_<name>
  return 0
}

# ---- main ------------------------------------------------------------------
grids=()
if [ -n "${GRID:-}" ]; then grids=("$GRID"); else
  while IFS= read -r g; do [ -n "$g" ] && grids+=("$g"); done < <(discover_grids)
fi
[ "${#grids[@]}" -gt 0 ] || die "no Steam shortcuts.vdf found (add a non-Steam game first, or set STEAM_ROOT/GRID)"

for g in "${grids[@]}"; do process_grid "$g"; done

if [ "$DO_FS" = "1" ]; then
  echo
  if steam_running && [ "${ALLOW_STEAM_RUNNING:-0}" != "1" ]; then
    echo "fullscreen: SKIPPED — Steam is running (it would overwrite the change on exit)."
    echo "            Fully quit Steam, then rerun with --fullscreen."
  else
    wrapper_arg=""
    for g in "${grids[@]}"; do
      vdf="$(dirname "$g")/shortcuts.vdf"
      [ -f "$vdf" ] || continue
      if grep -aq 'app.zen_browser.zen' "$vdf" 2>/dev/null; then
        install_zen_wrapper; wrapper_arg="$ZEN_WRAPPER"
        echo "==> esc launcher: $ZEN_WRAPPER"
      fi
      echo "==> fullscreen: $vdf"
      apply_fullscreen "$vdf" "$wrapper_arg" | sed 's/^/    /'
      apply_app_quirks "$vdf" | sed 's/^/    /'
    done
  fi
fi

echo
echo "Done. Fully restart Steam (Steam -> Exit, reopen) to load the changes."
