---
name: hermes-container-upgrade
description: "Upgrade, roll back, or version-check the Hermes Agent gateway running as an Apple `container` on this Mac. Use this whenever the user mentions upgrading/updating hermes, checking whether a newer hermes release exists, hermes being out of date, rolling hermes back, or recreating the hermes container — and also when they ask to change anything about how that container is created (image tag, ports, mounts, network), because the run flags live in one shared config that the boot script and the upgrade script both source. Reach for this skill even if the user just says 'update hermes' without mentioning containers."
---

# Upgrading Hermes Agent in an Apple container

Hermes here is **not** a normal install. It runs as an Apple `container` named `hermes`
from a published image, and `~/.hermes` is bind-mounted to `/opt/data` inside it. Two
consequences drive everything below:

- **`hermes update` does not work.** It's a published image with no git tree; the command
  says so and exits. Upgrading means pulling a new image and recreating the container.
- **Recreating is not restarting.** Apple's `container` can't swap the image under an
  existing container, so `stop`/`start` will never pick up a new pull. You must
  `stop` → `rm` → `run`.

## Do it with the script, not by hand

`~/GitHub/hermes-deploy/container/hermes-upgrade.sh` implements the whole
procedure — check, backup, pull, recreate, verify, roll back on failure.

```
hermes-upgrade.sh --check    # report only; touches nothing
hermes-upgrade.sh            # upgrade if a newer release exists
hermes-upgrade.sh --force    # re-run the upgrade even if already current
```

It also runs unattended each night at 04:30 via the `com.nousresearch.hermes-upgrade`
LaunchAgent. Log: `~/Library/Logs/hermes-upgrade.log`.

The script, the boot script and the run-flags config all live in the
`hermes-deploy` repo (`~/GitHub/hermes-deploy`), and this skill is a symlink into
it. After a successful upgrade the script rewrites `HERMES_IMAGE_TAG` in the
repo's `container/hermes-container.conf`, so **the repo will have an uncommitted
one-line diff** — that is the intended record of the version change. Commit it.
Run `./verify.sh` in the repo after anything that recreates the container.

Prefer the script over hand-rolling the steps. Doing it by hand is how the container
lost its published ports once already — see *The flags trap* below.

## The single source of truth

`~/GitHub/hermes-deploy/container/hermes-container.conf` holds the image tag and
a `hermes_container_create()` function with the canonical run flags. **Both** the login
boot script (`start-hermes.sh`) and the upgrade script source it.

When changing how the container is created — ports, mounts, network, tag — change it
*there*, never in one caller. The two paths drifting apart is the failure mode this
layout exists to prevent.

## The flags trap

The container must be created with its published ports:

```
-p 8642:8642    # dashboard / API server (HERMES_DASHBOARD=1, API_SERVER_ENABLED=true)
-p 9119:9119
```

Omitting them is silent and nasty: the gateway starts, `hermes status` looks perfectly
healthy, the dashboard still answers on the *container* IP — but nothing is bound on the
Mac, so `localhost:8642` is dead. Nothing in the health checks catches it. After any
recreate, confirm with:

```
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8642/     # expect 404, not 000
```

`404` means the server is up and reachable. `000` means connection refused — the ports
were dropped.

## Release tags vs rolling tags

Pin to a version tag (`vYYYY.M.D`), not `latest` or `main`. Those two move without
review — during one session `latest` had been republished ten minutes earlier. The
script only ever considers tags matching `^v20\d\d\.\d+\.\d+(\.\d+)?$` and picks the
newest by publish date.

Available tags: https://hub.docker.com/r/nousresearch/hermes-agent/tags

## What rollback can and cannot undo

The script snapshots state with `hermes backup --quick` (config, `state.db`, `.env`,
auth, cron) into `~/.hermes/backups/` plus a plain copy of `config.yaml`, then restores
the config on rollback.

Be honest with the user about the limit: **a config auto-migration is not reversible by
running the old image again.** Hermes migrates `_config_version` on first run of a new
build (42 → 44 on one upgrade). Rolling the image back and restoring the old
`config.yaml` recovers the common case, but anything the newer build wrote into other
databases stays written. If an upgrade goes badly wrong, the `--quick` zip is the real
recovery artifact.

## Verifying an upgrade

Version and gateway status are necessary but not sufficient. Run all of these:

1. `hermes --version` matches the tag you pulled.
2. `hermes gateway status` reports running.
3. Text: `hermes -z "What is 17 * 23? Reply with just the number. Do not use any tools."` → `391`
4. Tools: `hermes -z "Use your terminal tool to run: echo HUP-OK . Report the exact output."` → `HUP-OK`
5. Vision, if the setup uses it: generate a throwaway image with distinctive text and ask
   `vision_analyze` to describe it. Content the model could not guess is the point.

**Then the resolver probes, which matter more than the `-z` runs.** A `hermes -z` one-shot
does not carry `agent.reasoning_effort` the way the gateway loop does, so a passing `-z`
is *not* evidence the gateway's request shape is correct:

```python
from agent.auxiliary_client import resolve_vision_provider_client as r
from hermes_constants import resolve_reasoning_config
from hermes_cli.config import load_config_readonly
from providers import get_provider_profile
p, c, m = r()                      # -> provider, client, vision model actually used
cfg = load_config_readonly()
model = cfg["model"]["default"]
prof = get_provider_profile(cfg["model"]["provider"])
print(prof.build_api_kwargs_extras(
    reasoning_config=resolve_reasoning_config(cfg, model), model=model))
```

Run it with `container exec -u hermes hermes /opt/hermes/.venv/bin/python -c '...'`.

Note the log line `Vision auto-detect: using main provider zai (glm-5v-turbo)` prints the
*provider default* before any `auxiliary.vision.model` override is applied — it is not
evidence of which model is in use. The probe above is.

## Always exec as the `hermes` user

`container exec` defaults to **root**, and root-created files under `/opt/data` are
root-owned inside the container where the gateway runs as uid 10000. Use
`container exec -u hermes hermes ...`, or the `hermes` wrapper on the Mac
(`~/.local/bin/hermes`), which already does.

## After upgrading, re-check local deviations

This install carries workarounds for upstream bugs. When a new version lands, check
whether they're still needed rather than carrying them forever:

- `agent/reasoning_effort.py` — `GLM53_EFFORTS` includes `medium`, but z.ai's
  `/api/paas/v4` rejects `medium` for `glm-5.3-flashx` (only `low`/`high`/`max` work).
  That table was verified against the *coding* endpoint. Hence `agent.reasoning_effort: low`.
  If upstream splits the vocabulary per endpoint, the pin can be relaxed.
- `agent/error_classifier.py` — `_REASONING_MANDATORY_PATTERN` is the bare literal
  `"reasoning is mandatory"`, so z.ai's differently-worded rejection never triggers the
  self-heal in `turn_recovery.py`.

### The zai guard plugin

`~/.hermes/plugins/model-providers/zai/__init__.py` closes both of the above at the
source, by wrapping the bundled profile's `build_api_kwargs_extras` so the offending
request is never sent:

- a `thinking: {"type": "disabled"}` is dropped for GLM-5.3 (which always reasons), so
  the truncation-continuation path can't produce a 400 the classifier won't recognise;
- `reasoning_effort` is clamped to low/high/max off the coding endpoint.

It survives image upgrades — user plugins load after bundled ones and
`register_provider` is last-writer-wins. Because it wraps rather than subclasses, it
inherits `env_vars`/`base_url`/`aliases`/`fallback_models` from upstream and becomes a
no-op if upstream fixes either bug.

**After an upgrade, re-run this** to confirm the guard still installs against the new
build (it should print `{} {}` — no `thinking` key):

```
container exec -u hermes hermes /opt/hermes/.venv/bin/python -c '
from providers import get_provider_profile
p = get_provider_profile("zai")
print(getattr(p, "_local_1210_guard", False),
      p.build_api_kwargs_extras(reasoning_config={"enabled": False, "effort": "none"},
                                model="glm-5.3-flashx",
                                base_url="https://api.z.ai/api/paas/v4"))'
```

## Manual procedure, if the script is unavailable

```sh
export HERMES_CONF="$HOME/GitHub/hermes-deploy/container/hermes-container.conf"
source "$HERMES_CONF"          # HERMES_CONF is what hermes_set_tag() rewrites
container exec -u hermes hermes /opt/hermes/.venv/bin/hermes backup --quick \
    -o /opt/data/backups/pre-upgrade-$(date +%Y%m%d-%H%M%S).zip
container image pull nousresearch/hermes-agent:<TAG>
container stop hermes && sleep 3 && container rm hermes && sleep 1
hermes_container_create <TAG>          # carries the ports, mount and network
# wait for the gateway, then run the verification steps above
```

Roll back by re-running the last two lines with the previous tag and restoring the saved
`config.yaml`.
