# gogs — private git service (HTTP only)

Ops manual for `services/gogs`. Design & decisions: [docs/gogs-design.md](../../docs/gogs-design.md).

Docker commands are executed **by the dev on the target machine** (macOS test or Linux VM). All commands below run from the repo root via just; they operate inside `services/gogs/`.

## Requirements (target machine)

- docker + docker compose v2
- this repo cloned; `just`, `dprint` installed (see root `AGENTS.md`)
- Linux VM only: host dirs are non-root-owned — run `just gogs-chown` after `gogs-init` if the container loops with `Permission denied` on `/data`.

## First start (dev runbook)

```bash
just bootstrap                    # create services/gogs/.env from .env.example
# edit services/gogs/.env:
#   GOGS_DOMAIN, GOGS_EXTERNAL_URL (http://<host>:8550/), GOGS_SECURITY_SECRET_KEY
#   generate secret:  openssl rand -hex 32
just gogs-init                    # create data/gogs, seed app.ini from the template
just gogs-chown                    # Linux VM only: set data/gogs owner to UID/GID 1000
just gogs-up                      # start the container
```

Open `http://<host>:8550/`.

- **First start only**: the **install wizard** appears once — on Gogs 0.14.x it is the only path that creates the DB schema. Keep Database type **SQLite3** and the pre-filled DB path (`/data/gogs/data/gogs.db`); set the admin account and Application URL `http://<host>:8550/`. Completing it writes `INSTALL_LOCK = true` into the data `app.ini`, so it is never shown again.
- Afterwards sign in as usual (register more users as needed).
- Verify afterwards with `just gogs-check` (PATH inside `/data`, DB file present, INSTALL_LOCK=true).

Verify clones work:

```bash
git clone http://<host>:8550/<owner>/<repo>.git
```

## Configuration

Deploy-layer values live in `services/gogs/.env` (see `.env.example`). Application config lives in `/data/gogs/conf/app.ini` (seeded from the committed `services/gogs/app.ini` template; per-env values and the secret are injected via `${ENV}` at startup — **the file on disk never contains the secret**). Edits to `app.ini` take effect after a container restart (`just gogs-restart`).

The SQLite DB file is pinned to `data/gogs/gogs/data/gogs.db` — it must stay under the mounted `/data` (the image default would write into the container layer and be lost on recreate). `just gogs-init` seeds `app.ini` only when it is missing; to apply a template change to an existing install (like this PATH pin), merge the new keys into the data copy (or delete `data/gogs/gogs/conf/app.ini` and re-run `gogs-init`), then restart.

| Key                        | Default                   |
| -------------------------- | ------------------------- |
| `GOGS_HTTP_PORT`           | `8550`                    |
| `GOGS_DOMAIN`              | required                  |
| `GOGS_EXTERNAL_URL`        | required                  |
| `GOGS_SECURITY_SECRET_KEY` | required                  |
| `GOGS_DATA_DIR`            | `../../data/gogs`         |
| `GOGS_BACKUP_DIR`          | `../../data/backups/gogs` |
| `GOGS_BACKUP_KEEP`         | `5`                       |

Notes:

- `GOGS_HTTP_PORT`: host HTTP port → container 3000.
- `GOGS_DOMAIN`: host/IP users reach (prod: VM LAN IP).
- `GOGS_EXTERNAL_URL`: `http://<DOMAIN>:<GOGS_HTTP_PORT>/`.
- `GOGS_SECURITY_SECRET_KEY`: env-injected secret (`openssl rand -hex 32`).
- `GOGS_DATA_DIR`: container data, compose-dir relative; absolute allowed.
- `GOGS_BACKUP_DIR`: backup output dir under the `data/` umbrella; absolute allowed (e.g. NAS).
- `GOGS_BACKUP_KEEP`: backups to keep.

## Daily operations

| Command                                       | What it does                                              |
| --------------------------------------------- | --------------------------------------------------------- |
| `just gogs-status` / `gogs-ps`                | container state                                           |
| `just gogs-logs`                              | follow logs (Ctrl-C to exit)                              |
| `just gogs-up` / `gogs-down` / `gogs-restart` | lifecycle                                                 |
| `just gogs-config`                            | render + validate compose                                 |
| `just gogs-init`                              | create data dirs + seed app.ini (first run)               |
| `just gogs-chown`                             | Linux VM only: fix data dir owner to UID/GID 1000         |
| `just gogs-shell`                             | shell inside the container                                |
| `just gogs-backup`                            | stop → tar data dir → start → prune to `GOGS_BACKUP_KEEP` |
| `just gogs-restore <backup.tar.gz>`           | stop → keep old data aside → restore → start              |
| `just gogs-update`                            | backup, then pull + recreate (see Upgrade)                |
| `just gogs-clean`                             | remove container/net + all cached gogs images; data kept  |

Backups are written to `$GOGS_BACKUP_DIR` (gitignored). Backups are per-environment — **do not restore a test backup into production** (`app.ini`/Domain would be wrong).

`just gogs-clean` stops the service, removes the container/network and **all cached gogs images** (the pinned tag is re-pulled on the next `just gogs-up`). It **keeps the container data** in `data/gogs`. To also wipe the data (destructive — back up first): `rm -rf data/gogs`.

## Upgrade

1. Bump the image tag in `services/gogs/compose.yaml` (pin change is a committed code change)
2. `just gogs-update` (backs up first, pulls the pinned tag, recreates)
3. Smoke test: login + HTTP clone
4. Append a row to the changelog below

Rollback: revert the tag in compose + restore a backup if needed.

## Troubleshooting

- **`git clone` returns 500 but `curl` to the same URL is 200** — the client is going through a local HTTP proxy (e.g. Privoxy on `127.0.0.1:1095`) that cannot reach the LAN host; the `500 Internal Privoxy Error` comes from the proxy, not Gogs. Bypass: `env -u http_proxy -u https_proxy -u all_proxy git clone …`, or add the host to `no_proxy`.
- **Users can't log in after `down`/`up`** — the DB was in the container layer: the install wizard rewrites `app.ini` `[database]` and can drop the `/data` PATH, so the SQLite file lived at `/app/gogs/...` and vanished on container recreate. Fix permanently: in `data/gogs/gogs/conf/app.ini` set `[database] TYPE = sqlite3` + `PATH = /data/gogs/data/gogs.db` (drop leftover postgres keys) and add `INSTALL_LOCK = true` under `[security]`; `sudo mkdir -p data/gogs/gogs/data` + `just gogs-chown`; restart; create an admin with `docker compose exec gogs gogs admin create-user --admin --config /data/gogs/conf/app.ini …`. Run `just gogs-check` before/after any wizard, down/up or upgrade.
- **`git clone` returns 500 right after first start** — the instance is not initialized yet (DB missing, install wizard pending) or the repo/user lives on a different instance. Complete the wizard on this host, then (re)create the repo here.
- **Container loops with `mkdir: can't create directory '/data/git': Permission denied` (Linux VM)** — the host data dir is owned by the wrong user; the non-root container (UID 1000) cannot create subdirs. Fix with `just gogs-chown` (or `sudo chown -R 1000:1000 data/gogs`), then `just gogs-restart`.
- **Container refuses to start** — most likely a missing/unsafe `SECRET_KEY` or missing `app.ini`: re-run `gogs-init`, make sure `.env` has a generated `GOGS_SECURITY_SECRET_KEY`.
- **`.env` expansion looks empty** — values come from the container environment; check `just gogs-config` shows the right `environment:` block.
- **Permission errors on the data dir (Linux VM)** — image runs as UID/GID 1000 and does not auto-chown:

  ```bash
  docker run --rm -v "$PWD/data/gogs":/d alpine chown -R 1000:1000 /d
  ```

  (run from the repo root)

- **Wrong clone URL / port** — `app.ini` env values are resolved at **first start** and persisted into `data/gogs/gogs/conf/app.ini`; to change DOMAIN/URL afterwards, edit that file (or refresh it from the committed template) and `just gogs-restart`.

## Deployment log

First deploy (production VM, filled by dev):

- Host: vm001 · `GOGS_HTTP_PORT`: 8550 · Deployed: 2026-09
- Verified: wizard-once admin (INSTALL_LOCK afterwards) ☑ · HTTP clone (public, direct) ☑ · first push ☑
- Backup→restore drill: **postponed** — test when the first real restore is needed

## Changelog

| Date | Image tag | Notes |
| ---- | --------- | ----- |
