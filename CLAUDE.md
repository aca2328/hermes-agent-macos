# CLAUDE.md — hermes-deploy

This repo is the deployment of a **live service**. Editing a file here changes how the
Hermes gateway on this Mac boots and upgrades. Read [README.md](README.md) and
[docs/traps.md](docs/traps.md) before changing anything under `container/`.

## The rule that governs everything

The container mounts **only** `~/.hermes` → `/opt/data`. `/Users/YOUR_USERNAME/GitHub` does
not exist inside it.

- A file the **container** reads must be a real file under `~/.hermes`. Never symlink
  one into this repo — it dangles on the inside and fails silently. `install.sh`
  **copies** those.
- A file only the **Mac** reads can be symlinked, and is.

If you add an artifact, decide which side reads it *first*, then pick the mechanism.

## Never hand-roll a `container run`

The canonical run flags live in exactly one place: `hermes_container_create()` in
`container/hermes-container.conf`. Both `start-hermes.sh` and `hermes-upgrade.sh` source
it. Changing ports, mounts, network, env or the image tag means editing **that
function** — never a caller, and never an ad-hoc command line.

This repo exists because those two paths once disagreed and the container came up
without `-p 8642 -p 9119`.

## `HERMES_CONF` is load-bearing

Each caller sets `HERMES_CONF` to the conf file it is about to source, and
`hermes_set_tag()` rewrites `${HERMES_CONF:?}`. Do not hardcode a conf path anywhere.

If you get this wrong the failure is silent and delayed: the nightly upgrade writes the
new tag to a file nothing reads, and the next reboot recreates the container on a stale
tag. `hermes-upgrade.sh --check` exits before `hermes_set_tag` and will report green.
`verify.sh` is what actually asserts this.

## Runtime state is not owned here

Never commit, and never have `install.sh` write:

- `~/.hermes/config.yaml` — rewritten by `hermes config set` and by the rollback path.
  `reference/config.yaml` is a dated **snapshot** for comparison only.
- `~/.hermes/.env` — real secrets. `.env.example` holds names with every value stripped;
  regenerate it with the anchored sed in its header, never `sed 's/=.*/=/'` (that
  mangles the comment separators).
- `generated_credentials.txt`, the SQLite databases, logs, sessions.

Audit before any `git add`: `git status --short` must list no `.env`, and a grep for
`sk-`, `pplx-`, `gho_`, `ghp_` must return only upstream placeholder text.

## Verify, don't assume

After any change that touches the container, launchd, or the zai plugin:

```sh
./verify.sh
```

It checks plugin drift, the symlinks, that both LaunchAgents resolve into this repo,
that `hermes_set_tag` targets this repo's conf, and that 8642 answers `200` and 9119
answers `302`. A passing `hermes-upgrade.sh --check` is **not** a substitute — it exits
early and proves much less than it appears to.

## A dirty working tree after an upgrade is expected

`hermes_set_tag` rewrites `HERMES_IMAGE_TAG` in a committed file. A one-line diff after
a successful nightly upgrade is the intended record of the version change, not drift.
Commit it.

## Conventions

- `zsh`, absolute paths for binaries (launchd hands scripts a minimal PATH).
- Scripts resolve their own directory with `${0:A:h}` so the repo can live anywhere.
- `.plist.example` with a `YOUR_USERNAME` placeholder, committed `.env.example`, real
  secrets gitignored.
- Docs are written generically, with placeholders (`YOUR_USERNAME`, `<your-network>`,
  `<your-subnet>`, `<your-gateway>`, `<your-dns-domain>`). Real values live in
  `container/site.conf` and `docs/LOCAL.md`, so the public mirror is produced by
  verification rather than a search-and-replace over prose. **Do not write a site value
  into a doc** — put it in `site.conf` and reference the placeholder.
- Commit messages: imperative, under 40 characters.
