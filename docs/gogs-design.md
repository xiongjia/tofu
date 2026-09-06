# gogs-design — services/gogs (v1)

Status: operational (in use) · verified on macOS & Linux (dev) · Scope: v1 initial deployment

> Facts verified against the official `docker/README.md` and `docker-next/README.md` (gogs/gogs@main), checked 2026-09.

## 1. Goal & scope

Provide a **private git service (Gogs)** on the homelab, managed the "service-as-directory" way: everything declared under `services/gogs/` is committed; data and secrets are not.

v1 non-goals: external access / TLS, **SSH clone (HTTP only)**, multi-instance HA, many users, reverse proxy (see §13).

## 2. Environment & who executes what

- **Production**: a Linux VM (docker + docker compose v2) for daily use.
- **Test**: macOS (Docker Desktop), running the same declarations for validation/troubleshooting.
- The repo is cloned on both machines; **environment differences live only in `.env` values and each machine's `data/` umbrella** (runtime data + backups) — `compose.yaml` / `app.ini` / `.env.example` are identical.
- All relative paths are anchored to `services/gogs/` (the compose file directory); compose commands run only inside `services/gogs/`.
- **Execution responsibility**: the pi agent prepares files, config and runbooks; **actual docker/compose execution happens on the target machine, performed by the dev (owner)** — the agent environment is not guaranteed docker access. §10 is the dev deployment runbook.

## 3. Decisions

| Area         | Decision (summary)                                        |
| ------------ | --------------------------------------------------------- |
| Image        | `gogs/gogs:next-0.14.3` (next-gen, current usable stable) |
| Clone method | HTTP only (v1, SSH disabled)                              |
| Port         | container 3000 → host `GOGS_HTTP_PORT`, default `8550`    |
| Database     | SQLite                                                    |
| Data dir     | bind-mount host dir → `/data`                             |
| Config       | committed `app.ini` template + `${ENV}` injection         |
| Admin        | first registered user becomes admin                       |
| Access scope | LAN only, HTTP, no TLS                                    |
| Backup       | stop → tar data dir (`.env`-configurable)                 |
| Upgrade      | backup → bump pin → pull → recreate                       |

### 3.1 Rationale

- **Image**: the legacy `gogs/gogs:0.14.3` image is officially deprecated (renamed `legacy-latest` at 0.16.0, removed by 0.17.0; lacks modern security practices). Docker Hub currently has no newer stable release (no 0.15/0.16 tags), and `latest` tracks `main` development, so the next-gen `gogs/gogs:next-0.14.3` is the usable stable choice.
- **Clone method**: no SSH port/key management in v1; the built-in SSH server can be enabled later (see §13).
- **Port**: 3000 is too common and collides with local dev; 8550 is a high, uncommon port. The container-internal port stays 3000.
- **Database**: SQLite is the long-term choice — minimal single-machine footprint and backup as a plain copy of the data dir; **no PostgreSQL migration planned**.
- **Data dir**: bind-mounting a host directory keeps data visible, so backup is a plain tar and migration/troubleshooting is direct; named volumes are opaque.
- **Config**: Gogs requires a pre-existing `app.ini` with a safe `SECRET_KEY`. On Gogs 0.14.x the install wizard is the **only** path that creates the DB schema (`GlobalInit` skips DB init while unlocked; a locked empty DB does not self-bootstrap), so a fresh instance runs the wizard **once** with the pre-seeded `[database] PATH` kept; afterwards Gogs writes `INSTALL_LOCK = true` and the wizard never appears again. Secrets are injected via `${ENV}` and never stored on disk; `just gogs-check` guards PATH/DB/INSTALL_LOCK.
- **Admin**: with `INSTALL_LOCK = true` there is no installer — the first registered user becomes admin (CLI `gogs admin create-user` is the alternative).
- **Access scope**: minimal v1 surface; TLS/reverse proxy is deferred (see §13).
- **Backup**: see §7.
- **Upgrade**: see §8.

## 4. Data & directory layout

All container state lives under `/data` — one mount is enough:

```text
data/gogs/                        # host: $GOGS_DATA_DIR (default ../../data/gogs)
└── (container /data)
    ├── git/gogs-repositories/    # git repos (app.ini [repository] ROOT, as shipped by the image)
    └── gogs/
        ├── conf/app.ini          # must be pre-created (template seed + env injection)
        ├── data/gogs.db          # SQLite
        └── log/
```

Backups live under the same `data/` umbrella: `data/backups/gogs/` (`$GOGS_BACKUP_DIR`, default `../../data/backups/gogs`) — the whole `data/` tree is gitignored.

Permissions: the **next-gen image runs as non-root UID/GID 1000 and does not auto-chown** (unlike legacy). On the Linux VM the host dir must be `chown -R 1000:1000` first (usually unnecessary on macOS Docker Desktop). Generic fix (Linux VM):

```bash
just gogs-init        # create dirs + seed app.ini on first run (run by dev)
just gogs-chown        # chown data dir to UID/GID 1000 (alpine helper, no host sudo)
```

## 5. Configuration

### 5.1 Deploy layer: `.env` (template `services/gogs/.env.example`)

| Key                        | Default                   |
| -------------------------- | ------------------------- |
| `GOGS_HTTP_PORT`           | `8550`                    |
| `GOGS_DOMAIN`              | (required)                |
| `GOGS_EXTERNAL_URL`        | (required)                |
| `GOGS_SECURITY_SECRET_KEY` | (required)                |
| `GOGS_DATA_DIR`            | `../../data/gogs`         |
| `GOGS_BACKUP_DIR`          | `../../data/backups/gogs` |
| `GOGS_BACKUP_KEEP`         | `5`                       |

Notes:

- `GOGS_HTTP_PORT`: host HTTP port → container 3000.
- `GOGS_DOMAIN`: host/IP users actually reach (production: VM LAN IP); injected into app.ini.
- `GOGS_EXTERNAL_URL`: `http://<DOMAIN>:<GOGS_HTTP_PORT>/`; injected into app.ini.
- `GOGS_SECURITY_SECRET_KEY`: strong random value (`openssl rand -hex 32` or a UUID); env-injected only, **never written into app.ini on disk**.
- `GOGS_DATA_DIR`: container data, relative to the compose dir; absolute paths allowed.
- `GOGS_BACKUP_DIR`: backup output dir under the `data/` umbrella (`data/backups/gogs`); absolute paths allowed (e.g. NAS).
- `GOGS_BACKUP_KEEP`: keep the latest N backups.

compose references everything via `${VAR}` and forwards `environment` to the container so app.ini can expand `${ENV}` at startup.

### 5.2 App layer: `app.ini` (committed template, no installer)

**Gogs refuses to start without a pre-existing `/data/gogs/conf/app.ini` with a safe `SECRET_KEY`** (it also refuses its unsafe default). The template deliberately leaves `INSTALL_LOCK` **unset**: in Gogs 0.14.x the install wizard is the only path that creates the DB schema (locked empty DBs do not self-bootstrap), so the first start shows the wizard once — the pre-seeded `[database] PATH` is kept, completing it writes `INSTALL_LOCK = true` and the wizard never returns. This avoids a wizard rewrite silently moving SQLite into the container layer (the earlier login-loss bug). Per-env values and secrets come from the container environment:

```ini
RUN_MODE = prod
RUN_USER = git

[server]
; Listen on all container interfaces so the published host port reaches it.
HTTP_ADDR     = 0.0.0.0
EXTERNAL_URL = ${GOGS_EXTERNAL_URL}
DOMAIN       = ${GOGS_DOMAIN}
; HTTP stays on the container default 3000 (unchanged); compose maps host ${GOGS_HTTP_PORT:-8550}
; SSH is disabled in v1 (START_SSH_SERVER defaults to false) — clone via HTTP

[repository]
ROOT = /data/git/gogs-repositories    ; as shipped by the image

[database]
TYPE = sqlite3
PATH = /data/gogs/data/gogs.db   ; must stay inside the mounted /data (the image
                                ; default /app/gogs/data/gogs.db lives in the
                                ; container layer and is lost on recreate)

[security]
SECRET_KEY = ${GOGS_SECURITY_SECRET_KEY}
```

- **app.ini on disk holds no secrets** (expanded from the environment at runtime) → the template is safe to commit.
- Bootstrap: `just gogs-init` copies the template into `data/gogs/conf/app.ini` when missing and pre-creates `data/gogs/conf` + `data/gogs/data` (avoid a read-only mount that would block the admin UI writing config back); afterwards the data copy is authoritative and git keeps the template in sync. Note Gogs resolves `${ENV}` values and **persists them into the data copy at first start** — later `.env` changes do not propagate; edit the data copy and restart.
- Editing app.ini requires a **container restart** to take effect.
- Admin: first start shows the **install wizard once** (creates the DB schema); create the admin account there. Afterwards `INSTALL_LOCK = true` and the wizard never appears (or use `docker compose exec gogs gogs admin create-user --admin --config /data/gogs/conf/app.ini ...`).

### 5.3 Test vs production differences

Only `.env` values differ (`GOGS_DOMAIN` / `GOGS_EXTERNAL_URL` / occupied ports); the `app.ini` template is shared, env-dependent values injected. `data/` is per-environment — **never restore a test backup into production** (§7).

## 6. Target compose shape (Phase 2)

```yaml
services:
  gogs:
    image: gogs/gogs:next-0.14.3
    restart: unless-stopped
    ports:
      - "0.0.0.0:${GOGS_HTTP_PORT:-8550}:3000"   # HTTP only, all host interfaces
    environment:                          # expanded by app.ini ${...} at startup
      GOGS_DOMAIN: ${GOGS_DOMAIN}
      GOGS_EXTERNAL_URL: ${GOGS_EXTERNAL_URL}
      GOGS_SECURITY_SECRET_KEY: ${GOGS_SECURITY_SECRET_KEY}
    volumes:
      - ${GOGS_DATA_DIR:-../../data/gogs}:/data
    # No healthcheck: the image/docs document none; rely on restart: unless-stopped
    # plus `just gogs-ps` / `just gogs-logs` (see §11).
```

No `container_name` (compose names it `gogs-gogs-1`) — avoids clashes between instances/clones on one host.

## 7. Backup & restore

- **Backup** (`just gogs-backup`, dev runs it): `docker compose stop` (SQLite consistency) → tar `$GOGS_DATA_DIR` → `$GOGS_BACKUP_DIR/gogs-<timestamp>.tar.gz` → `up` → prune to `$GOGS_BACKUP_KEEP`.
  - v1 chooses stop-then-tar: simple and reliable; the short outage window is acceptable at home (the next-gen image has no built-in cron backup).
- **Restore** (`just gogs-restore`): stop → move away/clear `$GOGS_DATA_DIR` → unpack → `up`.
- Backups are per-environment; **do not restore test backups into production** (app.ini/Domain would be wrong).
- **Backup drill**: canceled — the drill will be tested the first time a restore is actually needed (dev). Recipes (`gogs-backup`/`gogs-restore`) stay ready.

## 8. Upgrade

`just gogs-update` (dev runs it): backup → bump the pinned tag in compose → pull → recreate → smoke test (login + HTTP clone) → record in `services/gogs/README.md` changelog.
Rollback: revert the tag + restore a backup if needed. Note: at 0.16.0 the next-gen image becomes the default `latest` distribution — adjust the pin per official tags then.

## 9. Security (v1 baseline)

- LAN only: the VM firewall exposes only 8550 to trusted networks (host sshd port 22 is out of scope for this service).
- Non-root container (UID/GID 1000); strong random `SECRET_KEY`, env-injected only.
- First user is admin → right after deploy set a strong password and create a normal user for daily use.
- Give the production VM a fixed IP / DHCP reservation (`GOGS_DOMAIN` and clone URLs depend on it).
- Periodic backups; **restore drill: postponed** — test when the first real restore is needed (dev).

## 10. Init runbook (dev executes)

1. `just bootstrap` → generates `.env`; fill `GOGS_DOMAIN`/`GOGS_EXTERNAL_URL` (e.g. `http://192.168.x.x:8550/`), generate `GOGS_SECURITY_SECRET_KEY` (`openssl rand -hex 32`)
2. `just gogs-init`: create `data/gogs` dirs and seed `app.ini` from the template
3. **Linux VM only**: `just gogs-chown` (chown the data dir to UID/GID 1000 — otherwise the non-root container loops on `Permission denied`)
4. `just gogs-up`
5. Browser `http://<host>:8550`: register the first user (auto admin), set a strong password; or use CLI `gogs admin create-user`
6. Create a repo and verify **HTTP clone** (`http://<host>:8550/<owner>/<repo>.git`) push/pull
7. Write the full steps into `services/gogs/README.md`

## 11. Verification status & remaining (dev-owned)

Basic deployment is **verified by the dev on macOS and Linux VM** and the service is in use (chown/permission path, HTTP clone working from another host after the local-proxy bypass; see the service README troubleshooting). Reverse proxy is dev-owned; the backup→restore drill is **canceled** and will be tested when a restore is first actually needed.

Healthcheck: **none** — the image and official docs document no health endpoint, so v1 relies on `restart: unless-stopped` plus `just gogs-ps` / `just gogs-logs`.

Backfill when convenient (dev; update this doc and the service README):

- [ ] SQLite file confirmed at `data/gogs/gogs/data/gogs.db` on the Linux VM (post-PATH-fix instance)
- [ ] `gogs admin create-user` availability (if ever needed)

**Do not rely on assumptions** — update the docs from real runs.

## 12. Ops command contract (Phase 2)

Service-level `just gogs-<action>`: `up down restart logs ps status config init shell backup restore update clean`; check `.env` exists first (hint `just bootstrap` if missing). `clean` removes the container/network and all cached gogs images (re-pulled on next up) while keeping the data dir (see the service README). Docker commands are run by the dev on the target machine.

## 13. Non-goals / later (Phase 4+)

- Reverse proxy + TLS (caddy/traefik; would change `GOGS_EXTERNAL_URL` + port mapping) — dev decides/handles, outside repo tasks for now
- SSH clone (`START_SSH_SERVER = true` + `SSH_LISTEN_PORT`/mapping, needs container restart) — not planned unless needed
- Monitoring (status page / alerting)

Database is SQLite for the long term — **no PostgreSQL migration planned** (see §3.1).

## 14. References

- Docker (legacy, deprecation note): https://github.com/gogs/gogs/blob/main/docker/README.md
- Docker (next-gen): https://github.com/gogs/gogs/blob/main/docker-next/README.md
- Gogs config primer: https://gogs.io/fine-tuning/configuration-primer
- Docker Hub tag: `gogs/gogs:next-0.14.3`
- Repo conventions: root `AGENTS.md` (service-dir rules, just/format gates, git boundaries, docker executed by dev)
