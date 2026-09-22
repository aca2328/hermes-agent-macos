# Architecture

## What Hermes is, here

Hermes Agent runs as an **Apple `container`** named `hermes`, from a pinned published
image (`nousresearch/hermes-agent:vYYYY.M.D`). It is not a normal install, and several
things that look routine are not:

- **The CLI exists only inside the image.** `~/.local/bin/hermes` (this repo's
  `bin/hermes`) is a wrapper that `container exec`s into it.
- **`hermes update` refuses to run.** There is no git tree — it's a published image.
  Upgrading means pulling a new image and recreating the container.
- **Recreating is not restarting.** Apple's `container` cannot swap the image under an
  existing container, so `stop`/`start` will never pick up a new pull. Changing the
  image, ports, mounts or env requires `stop` → `rm` → `run`.
- **`container exec` defaults to root**, and root-created files under `/opt/data` are
  unwritable by the gateway process (uid 10000). Always pass `-u hermes`.

## The container

| | |
|---|---|
| Name | `hermes` |
| Network | `<your-network>` (pinned `<your-subnet>`, gateway `<your-gateway>`) |
| Mount | `~/.hermes` → `/opt/data` (virtiofs) — **the only mount** |
| Ports | `8642` API server, `9119` dashboard |
| Env | `HERMES_DASHBOARD=1` (must be a `-e` flag — see [traps.md](traps.md)) |
| Image tag | `HERMES_IMAGE_TAG` in `container/hermes-container.conf` |

All of this lives in exactly one place: `hermes_container_create()` in
`container/hermes-container.conf`. Both callers source it. Never hand-roll a
`container run`.

### The single mount is the constraint that shapes this repo

`/Users/YOUR_USERNAME/GitHub` **does not exist inside the container**. Verified. So any file
the *container* reads must be a real file under `~/.hermes` — a symlink into this repo
dangles on the inside. That is why `plugins/model-providers/zai/__init__.py` is copied
by `install.sh` rather than symlinked, and why it is the only artifact that can drift.
`verify.sh` exists to catch that drift.

Host-only files have no such constraint and are symlinked, so there is only ever one
copy: `bin/hermes` and `skills/hermes-container-upgrade`.

## Ports

| Port | Service | Expected probe |
|---|---|---|
| 8642 | API server | `curl -s -o /dev/null -w '%{http_code}' http://localhost:8642/health` → `200` |
| 9119 | Dashboard | `curl -s -o /dev/null -w '%{http_code}' http://localhost:9119/` → `302` |

Dashboard login is `admin`; the password is in `~/.hermes/generated_credentials.txt`
(runtime state, never in this repo).

**These ports are invisible when missing.** Omit `-p` on the create and the gateway
starts, `hermes status` looks healthy, and the services answer on the *container* IP —
but nothing binds on the Mac. This has happened. Probe after every recreate.

## Shared host infrastructure — context only, not owned here

This repo does not install or own any of the following. It is documented because the
deployment depends on it and a future reader will need to know it exists.

- **`<your-network>`** is a manually created Apple `container` network with a pinned
  subnet. Use one — never the auto-created `default` network, which has no pinned subnet,
  so `container system stop`/`start` lets it silently pick a new one and breaks anything
  that assumed the old gateway address. Create it with:
  `container network create <your-network> --subnet <your-subnet>`
- **DNS**: `~/.config/container/config.toml` sets `domain = "<your-dns-domain>"`, and
  `sudo container system dns create <your-dns-domain>` routes it on macOS. Every
  container on `<your-network>` auto-registers as `<name>.<your-dns-domain>`, resolvable from
  the Mac and from other containers.
- **Ollama** runs on the Mac and must be reachable from the container subnet.
  `start-hermes.sh` resolves the `<your-network>` gateway IP, sets `OLLAMA_HOST`, and restarts
  Ollama if it is not bound there.
- **Other containers may share `<your-network>`.** They own their own boot scripts in
  their own repos; this one neither installs nor owns them. If `start-hermes.sh` on your
  machine also starts a sibling container, that is a local arrangement — see
  `docs/LOCAL.md` if this is the private copy.

The concrete values for a given machine live in `container/site.conf`, and
`docs/LOCAL.md` (private only) is the prose companion.

## Boot and upgrade paths

```
login
  └─ com.nousresearch.hermes-agent  (RunAtLoad)
       └─ container/start-hermes.sh
            ├─ sources container/hermes-container.conf   (HERMES_CONF)
            │    └─ which sources container/site.conf    (${HERMES_CONF:h}/site.conf)
            ├─ waits for the container system, resolves the Ollama gateway
            └─ starts hermes, or hermes_container_create on the pinned tag if absent

nightly 04:30
  └─ com.nousresearch.hermes-upgrade
       └─ container/hermes-upgrade.sh
            ├─ sources container/hermes-container.conf   (HERMES_CONF, + site.conf)
            ├─ current tag from the running container (conf is the fallback)
            ├─ newest vYYYY.M.D tag from Docker Hub (latest/main deliberately ignored)
            ├─ backup → pull → recreate → verify → roll back on failure
            └─ hermes_set_tag rewrites HERMES_IMAGE_TAG in the repo conf
```

`hermes_set_tag` rewriting a committed file means **the repo gets an uncommitted
one-line diff after any successful upgrade**. That is intended: it is the reviewable
record of the version change. Commit it. `verify.sh` does not treat it as drift.

## Security posture — the tradeoff to decide deliberately

Check this combination on your own deployment, because the default is permissive and
nothing warns you:

**If the API server binds `0.0.0.0` while `terminal.backend` is `local`, work dispatched
to port 8642 runs unsandboxed as your Mac user.** `API_SERVER_KEY` is the only gate.
That is a reasonable posture on a trusted single-user machine behind a firewall, and a
bad one on a shared or portable one.

Tightening options, in increasing order of cost:

- `-e API_SERVER_HOST=127.0.0.1` on the create — loopback only
- firewall the port
- `terminal.backend: docker` — sandbox the execution itself

Whichever you pick, make it a decision rather than a default, and record it. This repo
documents the tradeoff but does not impose a choice: `config.yaml` is runtime state and
is not owned here.
