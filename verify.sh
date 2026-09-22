#!/bin/zsh
# verify.sh — the drift guard this repo exists for.
#
# Checks, in order:
#   1. the zai plugin in ~/.hermes matches the repo copy (the only artifact that
#      is copied rather than symlinked, so the only one that CAN drift)
#   2. the symlinked host-only files still point into this repo
#   3. both LaunchAgents resolve to scripts inside this repo
#   4. hermes_set_tag() rewrites THIS repo's conf, not a stale path elsewhere
#   5. the run flags still resolve through site.conf -- network, both ports,
#      the mount and the dashboard env var all survive
#   6. the gateway actually answers on the Mac: 8642 -> 200, 9119 -> 302
#
# Exit 0 = everything green, 1 = at least one check failed.

set -u

REPO="${0:A:h}"
DOMAIN="gui/$(id -u)"
FAILED=0

pass() { print -r -- "  PASS  $*"; }
fail() { print -r -- "  FAIL  $*"; FAILED=1; }
section() { print -r -- ""; print -r -- "$*"; }

# ---------------------------------------------------------------- 1. drift
section "zai plugin (repo vs live ~/.hermes copy)"
ZAI_SRC="$REPO/plugins/model-providers/zai/__init__.py"
ZAI_DST="$HOME/.hermes/plugins/model-providers/zai/__init__.py"
# Compare the FILE, not the directory: ~/.hermes/.../zai/ also holds __pycache__,
# which is not and must not be in the repo.
if [ ! -f "$ZAI_DST" ]; then
  fail "$ZAI_DST is missing — the z.ai 1210 guard is not installed"
elif [ -L "$ZAI_DST" ]; then
  fail "$ZAI_DST is a symlink — it dangles inside the container; run ./install.sh"
elif /usr/bin/cmp -s "$ZAI_SRC" "$ZAI_DST"; then
  pass "identical"
else
  fail "DRIFT — repo and ~/.hermes disagree:"
  /usr/bin/diff "$ZAI_SRC" "$ZAI_DST" | /usr/bin/sed 's/^/        /'
fi

# ---------------------------------------------------------------- 2. symlinks
section "symlinked host-only files"
check_link() {  # $1 = link, $2 = expected target
  if [ ! -L "$1" ]; then
    fail "$1 is not a symlink into the repo"
  elif [ "$(/usr/bin/readlink "$1")" = "$2" ]; then
    pass "$1 -> repo"
  else
    fail "$1 -> $(/usr/bin/readlink "$1") (expected $2)"
  fi
}
check_link "$HOME/.local/bin/hermes" "$REPO/bin/hermes"
check_link "$HOME/.claude/skills/hermes-container-upgrade" "$REPO/skills/hermes-container-upgrade"

# ---------------------------------------------------------------- 3. launchd
section "LaunchAgents point into the repo"
for label in com.nousresearch.hermes-agent com.nousresearch.hermes-upgrade; do
  out="$(/bin/launchctl print "$DOMAIN/$label" 2>/dev/null)"
  if [ -z "$out" ]; then
    fail "$label is not loaded"
    continue
  fi
  if print -r -- "$out" | /usr/bin/grep -q "$REPO/container/"; then
    pass "$label -> repo"
  else
    fail "$label does not reference $REPO/container/ — still on the old path?"
    print -r -- "$out" | /usr/bin/grep -A4 'arguments' | /usr/bin/sed 's/^/        /'
  fi
done

# ---------------------------------------------------------------- 4. set_tag
section "hermes_set_tag() rewrites this repo's conf"
# This is the check that `hermes-upgrade.sh --check` can never make: --check
# exits at "up to date", long before set_tag runs. Writing the tag back over
# itself is a content no-op but proves the path resolved to the right file.
BEFORE="$(/sbin/md5 -q "$REPO/container/hermes-container.conf")"
PROBE="$(zsh -c '
  HERMES_CONF="'"$REPO"'/container/hermes-container.conf"
  source "$HERMES_CONF"
  hermes_set_tag "$HERMES_IMAGE_TAG"
' 2>&1)"
AFTER="$(/sbin/md5 -q "$REPO/container/hermes-container.conf")"
if [ -n "$PROBE" ]; then
  fail "set_tag errored: $PROBE"
elif [ "$BEFORE" != "$AFTER" ]; then
  fail "set_tag rewrote the conf with different content — inspect: git diff"
else
  pass "targets $REPO/container/hermes-container.conf"
fi

# ---------------------------------------------------------------- 5. run flags
section "run flags survive site.conf resolution"
# Check 4 exercises hermes_set_tag, which never reads site.conf -- so it proves
# nothing about the site values. This echoes the create command instead of
# running it, and asserts every flag that has gone missing before.
# CONTAINER_BIN is stubbed to /bin/echo so the REAL hermes_container_create runs
# and prints exactly the argv it would have executed.
FLAGS="$(zsh -c '
  HERMES_CONF="'"$REPO"'/container/hermes-container.conf"
  source "$HERMES_CONF" || exit 1
  CONTAINER_BIN=/bin/echo
  hermes_container_create
' 2>&1)"
if [ -z "$FLAGS" ]; then
  fail "could not resolve the run flags — is container/site.conf present?"
else
  missing=""
  print -r -- "$FLAGS" | /usr/bin/grep -q -- "-p 8642:8642"        || missing="$missing -p8642"
  print -r -- "$FLAGS" | /usr/bin/grep -q -- "-p 9119:9119"        || missing="$missing -p9119"
  print -r -- "$FLAGS" | /usr/bin/grep -q -- "-e HERMES_DASHBOARD=1" || missing="$missing dashboard-env"
  print -r -- "$FLAGS" | /usr/bin/grep -q -- "/opt/data"           || missing="$missing mount"
  print -r -- "$FLAGS" | /usr/bin/grep -qE -- "--network [^ ]+"    || missing="$missing network"
  print -r -- "$FLAGS" | /usr/bin/grep -q -- "--network  *$"       && missing="$missing empty-network"
  if [ -n "$missing" ]; then
    fail "missing from the create:$missing"
    print -r -- "        $FLAGS"
  else
    pass "network, both ports, mount and dashboard env all present"
  fi
fi

# ---------------------------------------------------------------- 6. live
section "gateway is reachable on the Mac (published ports)"
probe() {  # $1 = url, $2 = expected code, $3 = what it is
  local code
  code="$(/usr/bin/curl -s -o /dev/null -w '%{http_code}' -m 10 "$1" 2>/dev/null)"
  if [ "$code" = "$2" ]; then
    pass "$3 $1 -> $code"
  else
    fail "$3 $1 -> ${code:-no response} (expected $2) — are -p 8642 / -p 9119 on the create?"
  fi
}
probe "http://localhost:8642/health" 200 "API server "
probe "http://localhost:9119/"       302 "dashboard  "

print -r -- ""
if [ $FAILED -eq 0 ]; then
  print -r -- "all checks passed"
else
  print -r -- "FAILURES above — see docs/traps.md"
fi
exit $FAILED
