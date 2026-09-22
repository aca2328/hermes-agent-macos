# Traps

Every one of these has actually bitten. They share a shape: **two copies of the truth,
drifting apart, with nothing that fails loudly when they disagree.** That is what this
repo and `verify.sh` exist to stop.

---

## 1. Published ports are invisible when missing

`-p 8642:8642 -p 9119:9119` must be on the `container run`. Omit them and the gateway
starts, `hermes status` reports healthy, and both services answer on the *container* IP
— but nothing binds on the Mac. There is no error anywhere.

This happened because the upgrade path hand-rolled its own `container run` and dropped
the flags the boot script had. The fix is structural: the flags live only in
`hermes_container_create()` in `container/hermes-container.conf`, and both paths source
it.

**Check after every recreate** (`verify.sh` does this):

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8642/health   # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9119/         # 302
```

## 2. `HERMES_DASHBOARD=1` must be a container env var, not a `.env` entry

The s6 dashboard service reads it through `with-contenv`, i.e. from the **container**
environment. `~/.hermes/.env` is read only by the Python process, so s6 sees nothing,
the run script exits 0, and the slot is marked permanently down — a supervised dashboard
with no dashboard behind it, and no error.

So it is `-e HERMES_DASHBOARD=1` on the create. The dashboard's *basic-auth credentials*
go the other way: the Python process does read `.env`, so they belong there, and no
secret is duplicated into the conf file or the process list.

## 3. `hermes_set_tag()` must rewrite the conf that was actually sourced

Found while relocating the files into this repo, and worth stating plainly because the
existing checks did not cover it.

`hermes_set_tag()` used to hardcode
`$HOME/Library/Application Support/HermesAgent/hermes-container.conf`. Move the conf into
the repo and leave that hardcoded, and the failure is silent and delayed:

1. the nightly upgrade succeeds and writes the new tag — to the old file, which nothing
   reads any more;
2. the repo conf keeps the stale tag;
3. the next reboot runs `start-hermes.sh`, finds no container, and recreates it on the
   stale tag — **a silent downgrade.**

`hermes-upgrade.sh --check` cannot catch this: it exits at `log "up to date"`, long
before `hermes_set_tag` is reached. A green `--check` proves nothing here.

The fix: each caller sets `HERMES_CONF` to the file it is about to source
(`${0:A:h}/hermes-container.conf`), and `hermes_set_tag` uses `${HERMES_CONF:?}` — an
unset variable aborts loudly instead of writing to the wrong file. `verify.sh` asserts
it by calling `hermes_set_tag` with the tag it already has: a content no-op that proves
the path resolved.

## 4. The zai plugin cannot be a symlink

`/Users/YOUR_USERNAME/GitHub` does not exist inside the container — the only mount is
`~/.hermes` → `/opt/data`. Symlink `~/.hermes/plugins/model-providers/zai/__init__.py`
into this repo and it dangles on the inside: the plugin silently stops loading, the
z.ai 1210 guard goes with it, and GLM-5.3 turns start failing with a misleading
"thinking cannot be disabled" 400.

So `install.sh` **copies** it. That makes it the one artifact with two copies, hence the
one that can drift — which is precisely what `verify.sh`'s first check is for. Edit the
repo copy and re-run `install.sh`; never edit the `~/.hermes` copy directly.

Related: `install.sh` clears `__pycache__` after updating the file, because a stale
`.pyc` shadows the new source on the next import.

## 5. Each recreate takes the next IP on `<your-network>`

Observed going `.5` → `.13` over a single session. Never write a literal container IP
anywhere. Use the DNS name `hermes.<your-dns-domain>`.

## 6. A throwaway `container run` is not a quiet CLI

`container run --rm -v ~/.hermes:/opt/data <image> sh -c '<cli command>'` starts a
**full gateway**. The image's `02-reconcile-profiles` cont-init sees
`prior_state=running` and boots the gateway and dashboard inside your throwaway
container.

This cost a second pass during the SQLite conversion: that surprise gateway opened two
databases mid-run and the conversion correctly refused them. See
[rca-2026-09-22-sqlite-wal-virtiofs.md](rca-2026-09-22-sqlite-wal-virtiofs.md).

When you need to touch files under `~/.hermes` with nothing running, **stop the
container and work from the Mac.**

## 7. SQLite WAL on the virtiofs mount corrupts silently

`database.journal_mode` must be `delete`, never `wal`. Full write-up in the
[RCA](rca-2026-09-22-sqlite-wal-virtiofs.md). Re-check it after restoring a backup or
moving the data directory — and note that `config.yaml` is *not* owned by this repo, so
nothing here enforces it.

## 8. The repo will not stay clean after the first nightly upgrade

`hermes_set_tag` rewrites `container/hermes-container.conf` in place, so a successful
upgrade leaves an uncommitted one-line diff. This is **not** a bug and not drift — it is
the reviewable record of a version change that previously left no trace at all. Commit
it. `verify.sh` deliberately does not flag it.

## 9. `container exec` defaults to root

Root-created files under `/opt/data` are unwritable by the gateway (uid 10000). Always
pass `-u hermes`. `bin/hermes` already does.
