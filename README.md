# hermes-agent-macos

Run the [Hermes Agent](https://github.com/nousresearch/hermes-agent) gateway on macOS
with Apple's [`container`](https://github.com/apple/container) runtime, managed by
launchd.

Image: `nousresearch/hermes-agent`, pinned in `container/hermes-container.conf`
(currently `v2026.9.24`).

## Requirements

- macOS on Apple silicon with Apple `container` at `/usr/local/bin/container`
- `zsh`
- A subnet-pinned `container` network:
  `container network create <your-network> --subnet <your-subnet>`

## Install

```sh
git clone <repo-url> hermes-agent-macos
cd hermes-agent-macos
cp container/site.conf.example container/site.conf   # set network, subnet, gateway, DNS domain
./install.sh --dry-run
./install.sh
./verify.sh
```

`install.sh` is idempotent. It never writes `~/.hermes/config.yaml` or `~/.hermes/.env`;
use `.env.example` as the list of variable names.

## What it runs

One container, `hermes`, created only by `hermes_container_create()` in
`container/hermes-container.conf`:

- mount `~/.hermes` → `/opt/data` (the only mount)
- `-p 8642` API server, `-p 9119` dashboard
- `-e HERMES_DASHBOARD=1`
- command `gateway run`

Two LaunchAgents drive it:

| LaunchAgent | Script | Does |
|---|---|---|
| `com.nousresearch.hermes-agent` | `container/start-hermes.sh` | create/start at login |
| `com.nousresearch.hermes-upgrade` | `container/hermes-upgrade.sh` | check → backup → pull → recreate → verify → roll back on failure |

## Layout

```
install.sh                 symlink / copy / render LaunchAgents, then verify
verify.sh                  drift check + health probes (8642 → 200, 9119 → 302)
bin/hermes                 CLI wrapper, execs into the container (symlinked to ~/.local/bin)
container/                 run flags, site config, boot and upgrade scripts
launchd/*.plist.example    LaunchAgent templates
plugins/model-providers/zai/   z.ai error-1210 guard (copied into ~/.hermes)
skills/                    Claude Code skill for upgrades
reference/config.yaml      config snapshot, for comparison only
docs/                      architecture, traps, RCAs
```

Files the container reads are **copied** into `~/.hermes`; a symlink would dangle inside
the container. Host-only files are symlinked or referenced in place.

## Usage

| Task | Command |
|---|---|
| Check for an upgrade | `zsh container/hermes-upgrade.sh --check` |
| Upgrade | `zsh container/hermes-upgrade.sh` |
| Check for drift | `./verify.sh` |
| Run the CLI | `hermes ...` |
| Logs | `~/Library/Logs/hermes-upgrade.log`, `~/Library/Logs/hermes-launchd.log` |

A successful upgrade rewrites `HERMES_IMAGE_TAG` in `container/hermes-container.conf`.
Commit that diff.

## Notes

- Apple `container` cannot swap an image under a running container: upgrades are
  `stop` → `rm` → `run`. `hermes update` does not apply to the published image.
- Each recreate takes a new IP; address the container as `hermes.<your-dns-domain>`.
- The zai plugin is verified against `v2026.9.21` and becomes a silent no-op if upstream
  internals change. Re-check it after upgrades.
- SQLite WAL on the virtiofs mount can corrupt silently — see
  [docs/rca-2026-09-22-sqlite-wal-virtiofs.md](docs/rca-2026-09-22-sqlite-wal-virtiofs.md).
- The API server binds `0.0.0.0` with `terminal.backend: local`. Restrict access
  accordingly.

More in [docs/traps.md](docs/traps.md) and [docs/architecture.md](docs/architecture.md).

## License

See [LICENSE](LICENSE).
