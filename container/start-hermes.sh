#!/bin/zsh
# Started at login by com.nousresearch.hermes-agent LaunchAgent.
# Ensures Ollama is reachable from the Apple container subnet, then
# starts (or recreates) the hermes gateway container.

# Canonical image tag + container run flags, shared with hermes-upgrade.sh.
# Resolved next to this script so the repo can live anywhere; exported as
# HERMES_CONF because hermes_set_tag() rewrites exactly the file we sourced,
# and because hermes-container.conf resolves site.conf off it.
HERMES_CONF="${0:A:h}/hermes-container.conf"
source "$HERMES_CONF" || { echo "FATAL: could not load $HERMES_CONF"; exit 1 }

# Site values come from site.conf via the file above -- must be after the source.
NETWORK_NAME="$SITE_NETWORK"

echo "=== $(date) start-hermes.sh ==="

echo "Waiting for container system..."
/usr/local/bin/container system start >/dev/null 2>&1
for i in $(seq 1 30); do
  /usr/local/bin/container system status 2>/dev/null | grep -q "running" && break
  sleep 1
done

GATEWAY_IP=$(/usr/local/bin/container network inspect "$NETWORK_NAME" 2>/dev/null \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['status']['ipv4Gateway'])" 2>/dev/null)
OLLAMA_ADDR="${GATEWAY_IP:-$SITE_GATEWAY_IP}:11434"
echo "Using Ollama gateway address: $OLLAMA_ADDR"

launchctl setenv OLLAMA_HOST "$OLLAMA_ADDR"

is_bound() {
  /usr/sbin/lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | grep -q "$OLLAMA_ADDR"
}

if ! is_bound; then
  echo "Ollama not bound to $OLLAMA_ADDR yet, restarting it..."
  pkill -f "Ollama.app/Contents/MacOS/Ollama" 2>/dev/null
  sleep 2
  open -a Ollama
  for i in $(seq 1 20); do
    is_bound && break
    sleep 1
  done
fi

echo "Waiting for Ollama to answer on $OLLAMA_ADDR..."
for i in $(seq 1 30); do
  curl -sf -m 2 "http://$OLLAMA_ADDR/api/tags" >/dev/null 2>&1 && break
  sleep 1
done


if /usr/local/bin/container list -a 2>/dev/null | awk '{print $1}' | grep -qx "hermes"; then
  echo "Starting existing hermes container..."
  /usr/local/bin/container start hermes
else
  echo "hermes container missing, recreating it on ${HERMES_IMAGE_TAG}..."
  hermes_container_create
fi

echo "=== $(date) done ==="
