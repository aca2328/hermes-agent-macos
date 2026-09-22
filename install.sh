#!/bin/zsh
# install.sh — wire this repo into the running Mac. Idempotent: a second run
# reports "unchanged" for everything and touches nothing.
#
#   ./install.sh            install / repair
#   ./install.sh --dry-run  show what would change, change nothing
#
# Absolute paths throughout: launchd hands scripts a minimal PATH.
#
# What this does NOT do: it never writes ~/.hermes/config.yaml or ~/.hermes/.env.
# Those are runtime state (see reference/config.yaml and .env.example).

set -u

REPO="${0:A:h}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

LAUNCHAGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
CHANGED=0

# Displaced originals go HERE, never renamed in place. Renaming a skill
# directory to <name>.bak alongside the original leaves it inside
# ~/.claude/skills, where Claude Code still discovers it -- you get two skills
# with the same description and no way to tell which one wins.
BACKUPS="$HOME/Library/Application Support/HermesAgent/install-backups"

say()  { print -r -- "$*"; }
ok()   { print -r -- "  ok       $*"; }
did()  { print -r -- "  CHANGED  $*"; CHANGED=1; }
warn() { print -r -- "  WARN     $*"; }
run()  { [ $DRY -eq 1 ] && { print -r -- "  would run: $*"; return 0; }; "$@"; }

[ -r "$REPO/container/hermes-container.conf" ] || { say "FATAL: $REPO does not look like the repo"; exit 1; }
[ $DRY -eq 1 ] && say "(dry run — nothing will be changed)"

# ---------------------------------------------------------------- site.conf
# A fresh clone of the public mirror has only site.conf.example (site.conf is
# gitignored there). Without this, the boot path would fail its `[ -r ]` guard
# at login with no obvious cause. The private repo commits the real site.conf,
# so this is a no-op there.
say "site values"
SITE="$REPO/container/site.conf"
if [ -r "$SITE" ]; then
  ok "container/site.conf present"
elif [ -r "$SITE.example" ]; then
  run /bin/cp "$SITE.example" "$SITE"
  did "container/site.conf created from the example"
  warn "EDIT container/site.conf before relying on it — it holds placeholder values"
  warn "  network/subnet/gateway/DNS domain must match this machine"
else
  warn "neither container/site.conf nor site.conf.example exists — the boot path will fail"
  exit 1
fi

# ---------------------------------------------------------------- symlinks
# Host-only files: the Mac reads these, the container never does, so a symlink
# into the repo is safe and keeps exactly one copy of the truth.
link() {  # $1 = target in repo, $2 = link path
  local target="$1" link="$2"
  if [ -L "$link" ] && [ "$(/usr/bin/readlink "$link")" = "$target" ]; then
    ok "$link -> repo"
    return
  fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    local bak="$BACKUPS/$(basename "$link").bak-$(date '+%Y%m%d-%H%M%S')"
    run /bin/mkdir -p "$BACKUPS"
    run /bin/mv "$link" "$bak" || { warn "could not move $link aside"; return 1; }
    did "$link backed up to $bak"
  fi
  run /bin/mkdir -p "$(dirname "$link")"
  run /bin/rm -f "$link"
  run /bin/ln -s "$target" "$link" || { warn "could not link $link"; return 1; }
  did "$link -> repo"
}

say "symlinks (host-only files)"
link "$REPO/bin/hermes" "$HOME/.local/bin/hermes"
link "$REPO/skills/hermes-container-upgrade" "$HOME/.claude/skills/hermes-container-upgrade"

# ---------------------------------------------------------------- zai plugin
# THE ONE FILE THAT MUST BE A COPY. The container mounts only ~/.hermes; a
# symlink pointing at ~/GitHub dangles inside it and the plugin silently stops
# loading, taking the z.ai 1210 guard with it. See docs/traps.md.
say "zai plugin (copied, not linked — the container cannot follow a symlink out of /opt/data)"
ZAI_SRC="$REPO/plugins/model-providers/zai/__init__.py"
ZAI_DST="$HOME/.hermes/plugins/model-providers/zai/__init__.py"
if [ -L "${ZAI_DST:h}" ] || [ -L "$ZAI_DST" ]; then
  warn "$ZAI_DST is a symlink — that breaks inside the container; replacing with a real file"
  run /bin/rm -f "$ZAI_DST" "${ZAI_DST:h}"
fi
run /bin/mkdir -p "${ZAI_DST:h}"
if /usr/bin/cmp -s "$ZAI_SRC" "$ZAI_DST"; then
  ok "$ZAI_DST matches repo"
else
  run /bin/cp "$ZAI_SRC" "$ZAI_DST" && did "$ZAI_DST updated from repo"
  # A stale .pyc would shadow the new source on the next import.
  [ -d "${ZAI_DST:h}/__pycache__" ] && run /bin/rm -rf "${ZAI_DST:h}/__pycache__"
fi

# ---------------------------------------------------------------- LaunchAgents
# Rendered, not linked: launchd reads these at load time and a repo path in
# ~/Library/LaunchAgents is no more reviewable than a copy.
#
# Order matters. The upgrade agent is RunAtLoad=false and bootstrapping it has
# no side effects. The hermes-agent is RunAtLoad=true: bootstrapping it runs
# start-hermes.sh immediately, which may pkill and relaunch Ollama and will
# touch the running container. So it goes last, and only when its plist
# actually changed.
install_agent() {  # $1 = label
  local label="$1"
  local src="$REPO/launchd/${label}.plist.example"
  local dst="$LAUNCHAGENTS/${label}.plist"
  local tmp="${TMPDIR:-/tmp}/${label}.plist.$$"

  /usr/bin/sed "s|/Users/YOUR_USERNAME|$HOME|g" "$src" > "$tmp" || { warn "render failed: $label"; return 1; }

  if /usr/bin/cmp -s "$tmp" "$dst"; then
    ok "$label unchanged"
    /bin/rm -f "$tmp"
    return 0
  fi

  if [ $DRY -eq 1 ]; then
    print -r -- "  would install and reload $label:"
    /usr/bin/diff "$dst" "$tmp" 2>/dev/null | /usr/bin/sed 's/^/      /'
    /bin/rm -f "$tmp"
    CHANGED=1
    return 0
  fi

  /bin/mv "$tmp" "$dst" || { warn "could not write $dst"; return 1; }
  /bin/launchctl bootout "$DOMAIN/$label" 2>/dev/null
  if /bin/launchctl bootstrap "$DOMAIN" "$dst" 2>&1 | /usr/bin/grep -q .; then
    warn "$label: bootstrap reported something — check: launchctl print $DOMAIN/$label"
  fi
  did "$label installed and reloaded"
}

say "LaunchAgents"
install_agent com.nousresearch.hermes-upgrade
install_agent com.nousresearch.hermes-agent

say ""
if [ $CHANGED -eq 0 ]; then
  say "nothing to do — already installed"
else
  say "install complete. Run ./verify.sh to confirm."
fi
exit 0
