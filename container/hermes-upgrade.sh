#!/bin/zsh
# hermes-upgrade.sh — check for a newer Hermes Agent release, upgrade the Apple
# container, verify it, and roll back if verification fails.
#
#   hermes-upgrade.sh            check, and upgrade if a newer release exists
#   hermes-upgrade.sh --check    report only; never pull, recreate or test
#   hermes-upgrade.sh --force    re-run the upgrade even if already current
#
# Only version tags (vYYYY.M.D[.N]) are considered. The rolling `latest`/`main`
# tags are deliberately ignored: they move without review.
#
# Exit: 0 = up to date or upgrade verified · 1 = upgrade failed, rolled back
#       2 = upgrade failed AND rollback failed (needs a human) · 3 = setup error

set -u

# Resolved next to this script so the repo can live anywhere. HERMES_CONF is
# what hermes_set_tag() rewrites -- it must name the file we actually sourced.
CONF="${0:A:h}/hermes-container.conf"
HERMES_CONF="$CONF"
LOG="$HOME/Library/Logs/hermes-upgrade.log"
# Runtime state, deliberately NOT in the repo: a repo-relative lock would dirty
# the working tree on every run.
LOCK="$HOME/Library/Application Support/HermesAgent/.upgrade.lock"
CURL=/usr/bin/curl
PY=/usr/local/bin/python3
[ -x "$PY" ] || PY=/usr/bin/python3

MODE="run"
[ "${1:-}" = "--check" ] && MODE="check"
[ "${1:-}" = "--force" ] && MODE="force"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true; }

[ -r "$CONF" ] || { log "FATAL: missing $CONF"; exit 3; }
# Must be checked: the conf itself sources site.conf and returns non-zero if
# that is missing. Unchecked, this would continue with HERMES_NETWORK empty and
# recreate the container with `--network ""`.
source "$CONF" || { log "FATAL: could not load $CONF"; exit 3; }
[ -x "$CONTAINER_BIN" ] || { log "FATAL: $CONTAINER_BIN not executable"; exit 3; }

# Serialize against the boot script and any concurrent run.
if ! /bin/mkdir "$LOCK" 2>/dev/null; then
  log "another hermes-upgrade run holds the lock ($LOCK) — exiting"
  exit 0
fi
trap '/bin/rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

HERMES_BIN=/opt/hermes/.venv/bin/hermes
cexec() { "$CONTAINER_BIN" exec -u hermes "$HERMES_CONTAINER" "$@"; }

# ---- current tag: the running container is authoritative, conf is the fallback
current_tag() {
  "$CONTAINER_BIN" inspect "$HERMES_CONTAINER" 2>/dev/null \
    | "$PY" -c 'import sys,json
try:
    ref=json.load(sys.stdin)[0]["configuration"]["image"]["reference"]
    print(ref.rsplit(":",1)[-1])
except Exception:
    pass' 2>/dev/null
}

# ---- newest published release tag on Docker Hub
latest_tag() {
  "$CURL" -sf -m 30 \
    "https://hub.docker.com/v2/repositories/${HERMES_IMAGE_REPO}/tags?page_size=50&ordering=last_updated" \
  | "$PY" -c 'import sys,json,re
try:
    rows=json.load(sys.stdin).get("results",[])
except Exception:
    sys.exit(1)
pat=re.compile(r"^v20\d\d\.\d+\.\d+(\.\d+)?$")
for t in rows:                      # already newest-first
    if pat.match(t["name"]):
        print(t["name"]); break'
}

CUR="$(current_tag)"
[ -n "$CUR" ] || CUR="$HERMES_IMAGE_TAG"
NEW="$(latest_tag)"

if [ -z "$NEW" ]; then
  log "could not reach Docker Hub — leaving $CUR in place"
  exit 0
fi

log "installed=$CUR  latest_release=$NEW  mode=$MODE"

if [ "$CUR" = "$NEW" ] && [ "$MODE" != "force" ]; then
  log "up to date"
  [ "$MODE" = "check" ] && notify "Hermes" "Up to date ($CUR)"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  log "UPDATE AVAILABLE: $CUR -> $NEW (check mode, nothing changed)"
  notify "Hermes update available" "$CUR → $NEW"
  exit 0
fi

# ---------------------------------------------------------------- upgrade
STAMP="$(date '+%Y%m%d-%H%M%S')"
log "backing up state before upgrading"
cexec "$HERMES_BIN" backup --quick -o "/opt/data/backups/pre-upgrade-${CUR}-${STAMP}.zip" >>"$LOG" 2>&1 \
  || log "WARNING: hermes backup --quick failed; continuing with the config copy only"
/bin/mkdir -p "$HOME/.hermes/backups"
/bin/cp "$HOME/.hermes/config.yaml" "$HOME/.hermes/backups/config.yaml.${CUR}.${STAMP}" \
  || log "WARNING: could not copy config.yaml aside — rollback will not restore it"

log "pulling ${HERMES_IMAGE_REPO}:${NEW}"
if ! "$CONTAINER_BIN" image pull "${HERMES_IMAGE_REPO}:${NEW}" >>"$LOG" 2>&1; then
  log "FAILED: pull — nothing was changed"
  notify "Hermes upgrade failed" "Could not pull $NEW"
  exit 1
fi

recreate() {  # $1 = tag
  "$CONTAINER_BIN" stop "$HERMES_CONTAINER" >>"$LOG" 2>&1
  sleep 3
  "$CONTAINER_BIN" rm "$HERMES_CONTAINER" >>"$LOG" 2>&1
  sleep 1
  hermes_container_create "$1" >>"$LOG" 2>&1
}

wait_ready() {  # gateway answering, up to ~90s
  for i in $(seq 1 30); do
    sleep 3
    cexec "$HERMES_BIN" gateway status 2>/dev/null | grep -q "Gateway is running" && return 0
  done
  return 1
}

log "recreating container on $NEW"
recreate "$NEW"

# ---------------------------------------------------------------- verify
FAIL=""
wait_ready || FAIL="gateway did not come up"

if [ -z "$FAIL" ]; then
  V="$(cexec "$HERMES_BIN" --version 2>/dev/null | head -1)"
  log "version: $V"
  print -r -- "$V" | grep -q "${NEW#v}" || FAIL="version string does not match $NEW"
fi

if [ -z "$FAIL" ]; then
  OUT="$(cexec "$HERMES_BIN" -z 'What is 17 * 23? Reply with just the number. Do not use any tools.' 2>&1 | tail -1)"
  log "text check: $OUT"
  print -r -- "$OUT" | grep -q "391" || FAIL="text inference check failed"
fi

if [ -z "$FAIL" ]; then
  OUT="$(cexec "$HERMES_BIN" -z 'Use your terminal tool to run: echo HUP-OK . Report the exact output.' 2>&1 | tail -3)"
  log "tool check: $OUT"
  print -r -- "$OUT" | grep -q "HUP-OK" || FAIL="tool-calling check failed"
fi

if [ -z "$FAIL" ]; then
  # Resolver probes: these, not the -z runs, are what verify the gateway's own
  # request shape (reasoning effort + vision routing).
  OUT="$("$CONTAINER_BIN" exec -u hermes "$HERMES_CONTAINER" \
        /opt/hermes/.venv/bin/python -c '
from agent.auxiliary_client import resolve_vision_provider_client as r
from hermes_constants import resolve_reasoning_config
from hermes_cli.config import load_config_readonly
from providers import get_provider_profile
p,c,m = r()
cfg = load_config_readonly()
model = (cfg.get("model") or {}).get("default","")
prof = get_provider_profile((cfg.get("model") or {}).get("provider",""))
eb, tl = prof.build_api_kwargs_extras(reasoning_config=resolve_reasoning_config(cfg, model), model=model)
print("VISION", p, m)
print("PAYLOAD", eb, tl)
' 2>&1)"
  log "probes: $(print -r -- "$OUT" | tr '\n' ' ')"
  print -r -- "$OUT" | grep -q "^VISION" || FAIL="resolver probe failed"
fi

if [ -n "$FAIL" ]; then
  log "VERIFICATION FAILED: $FAIL — rolling back to $CUR"
  recreate "$CUR"
  /bin/cp "$HOME/.hermes/backups/config.yaml.${CUR}.${STAMP}" "$HOME/.hermes/config.yaml" 2>/dev/null
  if wait_ready; then
    log "rolled back to $CUR successfully"
    notify "Hermes upgrade rolled back" "$NEW failed: $FAIL"
    exit 1
  fi
  log "ROLLBACK ALSO FAILED — container is down, manual recovery required"
  notify "Hermes DOWN" "Upgrade and rollback both failed — needs attention"
  exit 2
fi

hermes_set_tag "$NEW"
log "UPGRADE OK: $CUR -> $NEW (all checks passed)"
notify "Hermes upgraded" "$CUR → $NEW — all checks passed"
exit 0
