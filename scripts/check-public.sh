#!/bin/zsh
# check-public.sh — refuse to publish a tree that carries local information.
#
#   scripts/check-public.sh <tree>     scan a directory (the export output)
#   scripts/check-public.sh --self-test   prove the detectors work, then exit
#
# Exit 0 = clean, 1 = findings, 2 = usage/setup error.
#
# TWO layers, deliberately. A deny-list only ever catches what someone thought
# of on the day they wrote it -- the same failure shape as a `--check` that
# exits early and reports green. The generic-shape layer catches the class,
# including values that did not exist when this file was written.
#
# This runs against the EXPORT OUTPUT and aborts the release before any push.
# It also runs in the public repo's CI, so a manual edit there cannot
# reintroduce anything.

set -u

# ---- layer 1: deny-list. Known-local strings. Extend freely; cheap and exact.
DENY=(
  'aca2328'
  'camerlo'
  'm4\.sdo'
  '172\.21\.21'
  'acadashb'
  'aviagent'
  'signal-cli'
  'claude\.ai/code/session'
  'LOCAL-ONLY'
)

# ---- layer 2: generic shapes. Catches the class, not the instance.
#
# Hostnames that are legitimate in a public repo. Everything else that looks
# like a hostname is reported for a human to judge.
ALLOW_HOSTS=(
  'github\.com' 'docker\.io' 'hub\.docker\.com' 'api\.z\.ai' 'z\.ai'
  'openai\.com' 'api\.openai\.com' 'localhost' 'example\.com' 'example\.org'
  'anthropic\.com' 'claude\.ai' 'nousresearch' 'python\.org' 'sqlite\.org'
  'openrouter\.ai' 'fireworks\.ai' 'app\.fireworks\.ai' 'novita\.ai'
  'aistudio\.google\.com' 'ollama\.com' 'platform\.kimi\.ai' 'minimax\.io'
  'opencode\.ai' 'huggingface\.co' 'deepinfra\.com' 'platform\.xiaomimimo\.com'
  'console\.upstage\.ai' 'app\.router\.com' 'tokenfactory\.nebius\.com'
  'tokenhub\.tencentmaas\.com' 'browserbase\.com' 'exa\.ai' 'parallel\.ai'
  'firecrawl\.dev' 'fal\.ai' 'app\.honcho\.dev' 'api\.hyperliquid\.xyz'
  'api\.slack\.com' 'bigmodel\.cn' 'moonshot\.cn' 'console\.mistral\.ai'
  'api\.kimi\.com' 'chat\.arcee\.ai' 'open\.bigmodel\.cn' 'api\.moonshot\.ai'
  'platform\.moonshot\.ai' 'novita\.ai' 'router\.com' 'nebius\.com'
)

# ---- files exempt from LAYER 2 ONLY. The deny-list still applies in full.
#
# .env.example is copied verbatim from the upstream image by release-public.sh,
# so every hostname and example IP in it is upstream's documentation, not this
# machine's infrastructure -- generic-shape hits there are all false positives.
# The deny-list is what protects it, and that is exactly the right division:
# layer 2 asks "is this somebody's infrastructure?", and for a vendored file the
# answer is "yes, the vendor's, on purpose".
#
# Add a path here only when the file's content is provably not ours.
EXEMPT_SHAPES=(
  '.env.example'
)

TREE="${1:-}"
[ "$TREE" = "--self-test" ] && SELFTEST=1 || SELFTEST=0

FOUND=0
SECTION_HITS=0
report() { print -r -- "  $1"; FOUND=1; SECTION_HITS=$((SECTION_HITS + 1)); }

# scan_tree <dir> -- prints findings, sets FOUND
scan_tree() {
  local dir="$1" pat hit

  # Text files only, excluding .git and this scanner itself (it contains the
  # deny-list, so it would flag itself).
  local -a files
  files=(${(f)"$(/usr/bin/find "$dir" -type f \
      -not -path '*/.git/*' \
      -not -name 'check-public.sh' 2>/dev/null)"})

  local -a text
  for f in $files; do
    /usr/bin/file "$f" 2>/dev/null | /usr/bin/grep -qE 'text|JSON|empty' && text+=("$f")
  done
  [ ${#text} -eq 0 ] && { print -r -- "  (no text files found under $dir)"; return }

  print -r -- "deny-list"
  SECTION_HITS=0
  for pat in $DENY; do
    # $text, not $shape_files: layer 1 applies to EVERY file, exemptions included.
    hit="$(/usr/bin/grep -rnIE -- "$pat" $text 2>/dev/null)"
    [ -n "$hit" ] && report "MATCH /$pat/:" && print -r -- "$hit" | /usr/bin/sed 's|^|      |'
  done
  [ $SECTION_HITS -eq 0 ] && print -r -- "  clean"


  print -r -- "generic shapes"
  SECTION_HITS=0

  # Layer 2 runs on everything except the vendored files. Layer 1 already
  # covered those in full.
  local -a shape_files
  for f in $text; do
    local rel="${f#$dir/}" skip=0
    for ex in $EXEMPT_SHAPES; do [ "$rel" = "$ex" ] && skip=1; done
    [ $skip -eq 0 ] && shape_files+=("$f")
  done
  if [ ${#shape_files} -lt ${#text} ]; then
    print -r -- "  (layer 2 skips $(( ${#text} - ${#shape_files} )) vendored file(s); layer 1 covered them)"
  fi
  [ ${#shape_files} -eq 0 ] && { print -r -- "  clean"; return }

  # RFC1918-shaped addresses. 10.0.0.0/24 and 192.0.2.x are documentation
  # placeholders and allowed; anything else private-shaped is a finding.
  hit="$(/usr/bin/grep -rnIE '(^|[^0-9.])(10|127|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}' $shape_files 2>/dev/null \
        | /usr/bin/grep -vE '10\.0\.0\.(0|1)([^0-9]|$)|127\.0\.0\.1|192\.0\.2\.')"
  [ -n "$hit" ] && report "private-range address:" && print -r -- "$hit" | /usr/bin/sed 's|^|      |'

  # /Users/<x> where <x> is not the placeholder.
  hit="$(/usr/bin/grep -rnIE '/Users/[A-Za-z0-9_.-]+' $shape_files 2>/dev/null \
        | /usr/bin/grep -vE '/Users/YOUR_USERNAME')"
  [ -n "$hit" ] && report "real home directory path:" && print -r -- "$hit" | /usr/bin/sed 's|^|      |'

  # Hostnames outside the allow-list.
  local allow_re="${(j:|:)ALLOW_HOSTS}"
  hit="$(/usr/bin/grep -rnIoE '[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\.(com|org|net|io|ai|dev|sh|co|me|cn|xyz|app|cloud|local|internal|lan|home|arpa)' $shape_files 2>/dev/null \
        | /usr/bin/grep -vE "($allow_re)" \
        | /usr/bin/grep -vE '\.(py|sh|md|yml|yaml|json|conf|example|plist|log|db|zip|txt)$')"
  [ -n "$hit" ] && report "hostname outside the allow-list (judge each):" && print -r -- "$hit" | /usr/bin/sed 's|^|      |'

  [ $SECTION_HITS -eq 0 ] && print -r -- "  clean"
}

# ---------------------------------------------------------------- self-test
# A scanner never seen to fail on a known-dirty input is not a scanner. This
# builds a fixture holding one instance of each detector's target and asserts
# every one is caught. Verifying instead by "it flags the private tree" would
# only prove that a file already known to be dirty is dirty.
if [ $SELFTEST -eq 1 ]; then
  FIX="$(/usr/bin/mktemp -d)"
  trap "/bin/rm -rf '$FIX'" EXIT INT TERM
  {
    print -r -- "user aca2328 lives here"
    print -r -- "domain m4.sdo.camerlo.org at camerlo"
    print -r -- "subnet 172.21.21.0/24"
    print -r -- "siblings acadashb aviagent signal-cli"
    print -r -- "session https://claude.ai/code/session_01ABC"
    print -r -- "marker LOCAL-ONLY here"
    print -r -- "path /Users/somebody/GitHub/thing"
    print -r -- "private ip 192.168.4.7 and 172.20.1.1"
    print -r -- "host internal.corp.example.net"
  } > "$FIX/dirty.md"

  # The layer-2 exemption is a hole by design. Prove it is not also a layer-1
  # hole: a local value hidden in an exempt file must still be caught.
  {
    print -r -- "# upstream template with a local value smuggled in"
    print -r -- "SOME_HOST=aca2328.internal.example.net"
  } > "$FIX/.env.example"

  print -r -- "self-test: scanning a fixture containing every target"
  print -r -- ""
  OUT="$(scan_tree "$FIX")"
  print -r -- "$OUT"
  print -r -- ""

  # Assert EVERY detector fired, not merely that something did. "$FOUND -eq 1"
  # would pass with a single deny-list hit and eight dead detectors.
  MISSED=()
  for pat in $DENY; do
    print -r -- "$OUT" | /usr/bin/grep -qF "MATCH /$pat/" || MISSED+=("deny:$pat")
  done
  print -r -- "$OUT" | /usr/bin/grep -q 'private-range address'  || MISSED+=("shape:rfc1918")
  print -r -- "$OUT" | /usr/bin/grep -q 'real home directory'    || MISSED+=("shape:home-path")
  print -r -- "$OUT" | /usr/bin/grep -q 'hostname outside'       || MISSED+=("shape:hostname")

  # The exempt file must be skipped by layer 2 but still caught by layer 1.
  print -r -- "$OUT" | /usr/bin/grep -q 'layer 2 skips'          || MISSED+=("exemption:not-applied")
  print -r -- "$OUT" | /usr/bin/grep -q '\.env\.example.*aca2328' || MISSED+=("exemption:denylist-hole")

  if [ ${#MISSED} -eq 0 ]; then
    print -r -- "self-test PASSED — all ${#DENY} deny-list patterns and 3 generic shapes fired"
    exit 0
  fi
  print -r -- "self-test FAILED — these detectors did not fire: ${MISSED[*]}"
  exit 1
fi

# ---------------------------------------------------------------- normal run
[ -n "$TREE" ] || { print -r -- "usage: $0 <tree> | --self-test"; exit 2; }
[ -d "$TREE" ] || { print -r -- "not a directory: $TREE"; exit 2; }

print -r -- "scanning $TREE"
print -r -- ""
scan_tree "$TREE"
print -r -- ""

if [ $FOUND -eq 0 ]; then
  print -r -- "CLEAN — safe to publish"
  exit 0
fi
print -r -- "FINDINGS ABOVE — refusing to publish"
exit 1
