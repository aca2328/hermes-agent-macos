# hermes-deploy

The deployment of the Hermes Agent gateway that runs as an Apple `container` on this Mac
— the run flags, the boot script, the upgrade script, the CLI wrapper, the one local
provider plugin, and the docs for the traps that have bitten.

It exists because that deployment used to live as loose files across four unrelated
directories, none of them version-controlled. Over a single session that cost real
breakage: a recreate silently dropped `-p 8642/-p 9119` and took the dashboard and API
server off `localhost`; the boot script hardcoded `:latest` and would have un-pinned the
release on any reboot where the container was missing; and `HERMES_DASHBOARD=1` sat in
`.env` where the s6 service that needs it can never read it. Each was the same shape:
two copies of the truth, drifting apart, with no history to diff.

Now a change to how the container is created is a commit.

**What is deliberately *not* here:** `~/.hermes` itself. It is 523 MB of runtime state —
vendored packages, `.env`, `generated_credentials.txt`, seven live SQLite databases,
logs and session dumps. This repo is the ~56 KB that describes the deployment.

## Install

```sh
git clone <your-remote> ~/GitHub/hermes-deploy
cd ~/GitHub/hermes-deploy
./install.sh --dry-run    # see what would change
./install.sh
./verify.sh
```

`install.sh` is idempotent — a second run reports "nothing to do". It never writes
`~/.hermes/config.yaml` or `~/.hermes/.env`.

## Layout

```
install.sh                  idempotent: symlink / copy / repoint launchd, then verify
verify.sh                   drift check + live health probes

bin/hermes                  the Mac-side CLI wrapper  -> symlinked to ~/.local/bin/hermes
container/
  hermes-container.conf     THE single source of truth for the run flags
  site.conf                 THIS machine's network, subnet, gateway, DNS domain
  start-hermes.sh           login boot script
  hermes-upgrade.sh         check -> backup -> pull -> recreate -> verify -> roll back
launchd/*.plist.example     rendered with the real $HOME by install.sh
plugins/model-providers/zai/__init__.py   the z.ai 1210 guard -- COPIED, see below
skills/hermes-container-upgrade/          -> symlinked to ~/.claude/skills/
reference/config.yaml       dated SNAPSHOT of ~/.hermes/config.yaml, not the live file
.env.example                variable NAMES only, generated from the live .env
docs/                       architecture, traps, the SQLite/virtiofs RCA
docs/LOCAL.md               private only: the real values behind the placeholders
```

## How artifacts are installed, and why it differs per file

The container mounts **only** `~/.hermes` → `/opt/data`. `/Users/YOUR_USERNAME/GitHub` does not
exist inside it. So anything the *container* reads must be a real file — a symlink into
this repo dangles on the inside. That single fact splits the artifacts three ways:

| Class | Files | Mechanism |
|---|---|---|
| Host-only | `container/*` | launchd points at the repo paths |
| Host-only | `bin/hermes`, the Claude skill | **symlinked** from the repo |
| Container-read | the zai plugin | canonical here, **copied** by `install.sh` |
| Runtime state | `config.yaml`, `.env` | **never owned here** — snapshot / `.env.example` |

The copied file is the only one that can drift, which is `verify.sh`'s first check.
**Edit the repo copy and re-run `install.sh`; never edit `~/.hermes` directly.**

## The zai plugin, and when it stops working

`plugins/model-providers/zai/__init__.py` closes two z.ai rejections that the bundled
stack cannot recover from — both HTTP 400 error 1210. It wraps the bundled profile's
`build_api_kwargs_extras` so it never sends `thinking: {"type":"disabled"}` to a model
that always reasons, and clamps `reasoning_effort` to low/high/max off the coding
endpoint.

**Verified against `nousresearch/hermes-agent:v2026.9.21`.** It wraps specific internals
(`providers.get_provider_profile`, `register_provider`), and it is written to degrade to
a **silent no-op** rather than fight a newer build — which is the safe failure, but it
means an upgrade can quietly remove the guard without any error.

Check it after any image upgrade:

```sh
container exec -u hermes hermes /opt/hermes/.venv/bin/python -c \
  'from providers import get_provider_profile as g; p=g("zai");
   print(getattr(p,"_local_1210_guard",False),
         p.build_api_kwargs_extras(reasoning_config={"enabled":False,"effort":"none"},
                                   model="glm-5.3-flashx",
                                   base_url="https://api.z.ai/api/paas/v4"))'
```

`True ({}, {})` means the guard is active. `False` means upstream changed something —
check whether the underlying bugs are fixed before reaching for a workaround.

## Runbook

| Task | Command |
|---|---|
| Is an upgrade available? | `zsh container/hermes-upgrade.sh --check` |
| Upgrade now | `zsh container/hermes-upgrade.sh` |
| Re-run an upgrade anyway | `zsh container/hermes-upgrade.sh --force` |
| Did anything drift? | `./verify.sh` |
| Change ports / mounts / env / tag | edit `container/hermes-container.conf`, then recreate |
| Run the CLI | `hermes ...` (the wrapper execs into the container) |
| Upgrade log | `~/Library/Logs/hermes-upgrade.log` |
| Boot log | `~/Library/Logs/hermes-launchd.log` |

**Never hand-roll a `container run`.** The canonical flags live in exactly one place,
`hermes_container_create()` in `container/hermes-container.conf`, and both the boot
script and the upgrade script source it. The two disagreeing is the failure this layout
prevents.

**Recreating is not restarting.** Apple's `container` cannot swap the image under an
existing container, so `stop`/`start` never picks up a new pull — it must be
`stop` → `rm` → `run`. And `hermes update` does not work at all: it is a published image
with no git tree.

## After a successful nightly upgrade, the repo will be dirty

`hermes_set_tag()` rewrites `HERMES_IMAGE_TAG` in `container/hermes-container.conf`, so
a successful upgrade leaves an uncommitted one-line diff. That is intended — it is the
reviewable record of a version change that previously left no trace. Commit it.
`verify.sh` does not treat it as drift.

## The traps

Short version; each is written up with its failure mode in [docs/traps.md](docs/traps.md).

1. **Published ports are invisible when missing** — the gateway looks healthy and binds
   nothing on the Mac.
2. **`HERMES_DASHBOARD=1` must be a `-e` flag**, not a `.env` entry — s6 reads it from
   the container environment; in `.env` you get a supervised dashboard with nothing
   behind it.
3. **`hermes_set_tag` must rewrite the conf that was sourced** — otherwise a successful
   upgrade writes the tag somewhere nothing reads and the next reboot silently
   downgrades. `--check` cannot catch it.
4. **The zai plugin cannot be a symlink** — it would dangle inside the container.
5. **Each recreate takes the next IP on `<your-network>`** — use `hermes.<your-dns-domain>`,
   never a literal IP.
6. **A throwaway `container run` is not a quiet CLI** — it boots a full gateway.
7. **SQLite WAL corrupts silently on the virtiofs mount** —
   [RCA](docs/rca-2026-09-22-sqlite-wal-virtiofs.md).

## Scope

Not owned here, on purpose:

- **Shared Apple `container` infra** — `<your-network>`, DNS, `/etc/resolver`. Described in
  [docs/architecture.md](docs/architecture.md) because the deployment depends on it, but
  this repo neither installs nor owns it.
- **Other containers on the same network** — they own their boot scripts in their own repos.
- **The unapplied security tightening** — the API server binds `0.0.0.0` while
  `terminal.backend` is `local`. Recorded in the docs as a known, accepted posture;
  changing it is a separate decision.
