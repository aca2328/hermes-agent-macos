# RCA — SQLite WAL on a virtiofs bind mount

**Date:** 2026-09-22
**Status:** resolved; `database.journal_mode: delete` set in `~/.hermes/config.yaml`

## Summary

The Hermes gateway wedged: ports 8642 and 9119 timed out and `container exec` took
minutes instead of seconds. It cleared on stop/start. In the same window,
`hermes_state` began logging ERRORs about an existing WAL-mode database on a cross-VM
filesystem.

No data loss was observed — `PRAGMA integrity_check` returned `ok` on all seven
databases afterwards.

## Impact

Gateway unreachable on both published ports until restarted. Six SQLite databases were
running in an unsafe journal mode for an unknown period before detection.

## Root cause

`database.journal_mode: wal` on a **virtiofs bind mount**. `~/.hermes` is mounted into
the container as `/opt/data`, and SQLite's WAL shared-memory is not coherent across the
VM boundary. Concurrent writers can silently corrupt the database — no crash, no error,
just bad data later.

Hermes's own config defaults warn about exactly this: use `delete` on weak-fsync or
shared filesystems where WAL is not crash-safe (macOS virtiofs, NFS, SMB).

Six databases were affected: `state.db`, `projects.db`, `kanban.db`,
`response_store.db`, `runs_idempotency.db`, `cron/executions.db`. `shared-state.db`
auto-selects DELETE and was already fine.

Hermes detects this condition and deliberately **will not live-downgrade** an existing
WAL database, because other processes may hold uncheckpointed commits. Conversion must
be done offline.

## Why it surfaced on this date

The nightly upgrade script ran with `--force` and upgraded v2026.9.14 → v2026.9.21, and
the ERROR-level cross-VM detection began at exactly that moment.

**Inferred, not verified** by diffing the two builds: the newer build added or
strengthened the check. The *risk* pre-existed; only the reporting was new.

## Wedge causation: unproven

The wedge and the WAL errors coincided. A `websockets` library race
(`RuntimeError: dictionary changed size during iteration` in
`acknowledge_pending_pings`) also crashed a TUI-gateway thread in the same window.

**No causal link was established between any of these.** Recorded rather than concluded.
If the container wedges again after dashboard use, that websockets crash is the thread
to pull first.

## Resolution

1. Set `database.journal_mode: delete` in `~/.hermes/config.yaml`.
2. Convert each existing database offline, with the container stopped.

## The trap that cost a second pass

The obvious way to run the conversion — a throwaway container with the data mounted —
does not work:

```sh
container run --rm -v ~/.hermes:/opt/data <image> sh -c '<cli command>'   # DON'T
```

That does **not** give a quiet CLI container. The image's `02-reconcile-profiles`
cont-init sees `prior_state=running` and starts a full gateway and dashboard inside the
throwaway container. That gateway opened two databases mid-run and the conversion
correctly refused them:

```
✗ Refusing to change the journal mode of /opt/data/response_store.db:
  other processes hold it open (a live switch would destroy their uncheckpointed commits)
```

Five databases converted before the gateway finished starting; two lost the race.

## Working procedure

With the container stopped, convert **from the Mac** — no container is involved, so
nothing can resurrect a gateway mid-run:

```sh
container stop hermes

for db in ~/.hermes/state.db ~/.hermes/projects.db ~/.hermes/kanban.db \
          ~/.hermes/response_store.db ~/.hermes/runs_idempotency.db \
          ~/.hermes/shared-state.db ~/.hermes/cron/executions.db; do
  [ -f "$db" ] && echo "$(basename $db) $(sqlite3 "$db" 'PRAGMA journal_mode=delete;')"
done
```

**Check `lsof` on the files first.** A blind `PRAGMA` has none of the guards that
`hermes sessions set-journal-mode delete` applies — that command refuses while a process
holds the file and verifies the header afterwards — so the `lsof` check is what
substitutes for them.

Afterwards: verify with `PRAGMA integrity_check`, and confirm no `-wal` / `-shm` files
remain.

## Follow-up

`config.yaml` is runtime state and is **not** owned by this repo — `hermes config set`
rewrites it, and `hermes-upgrade.sh`'s rollback path restores it from a backup. So
nothing here enforces `journal_mode: delete`. Re-check it after restoring a backup or
moving the data directory. `reference/config.yaml` holds a dated snapshot of the known-
good configuration for comparison.
