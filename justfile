# tofu — homelab service management: single command entrypoint
#
# Tools: dprint (formats md/toml/json), docker (service runtime), just itself.
# Install dprint: npm i -g dprint@0.57.1 (or brew/cargo). Keep local just aligned
# with CI (pinned via setup-just); `just check` is the source of truth.
#
# Service-level targets: `just <service>-<action>`. Recipes cd into
# services/<service> first, then run docker compose there — .env lookup and
# relative bind paths are anchored to the compose dir. Running compose from the
# repo root with -f would misresolve both.
# Actions: up down restart logs ps status config init chown shell backup restore update clean

default: list

# List repo services and container state
list:
    @echo "== services =="
    @if [ -d services ]; then find services -mindepth 1 -maxdepth 1 -type d | sort; else echo "  (no services dir yet)"; fi
    @echo "== containers =="
    @docker compose ls 2>/dev/null || echo "  (docker unavailable or no compose projects)"

# Create missing .env from each services/*/.env.example (idempotent)
bootstrap:
    @for d in services/*/; do \
        [ -d "$d" ] || continue; \
        if [ -f "$d.env.example" ] && [ ! -f "$d.env" ]; then \
            cp "$d.env.example" "$d.env" && echo "created $d.env"; \
        fi; \
    done
    @echo "bootstrap done"

# Environment self-check: dprint / docker / just
doctor:
    @for tool in dprint docker just; do \
        if command -v $tool >/dev/null 2>&1; then echo "ok:   $tool"; else echo "MISS: $tool"; fi; \
    done

# Format repo files (md/toml/json; future: Rust via cargo fmt, TS via dprint plugin)
fmt:
    dprint fmt

# Format checks (dprint check + justfile self-format); must be green before commit
check:
    dprint check
    just --fmt --check

# CI aggregate entrypoint (called by .github/workflows/ci.yml); extend here
ci: check

# ---------------------------------------------------------------
# Service recipes — service: gogs (private git, HTTP only)
# Docker compose ops run inside services/gogs; execute them as dev on the
# target machine (agent env may lack docker). See services/gogs/README.md
# and docs/gogs-design.md.

# Start the container (requires services/gogs/.env)
gogs-up:
    @cd services/gogs && { [ -f .env ] || { echo "missing services/gogs/.env — run: just bootstrap"; exit 1; }; } && docker compose up -d

# Stop the container
gogs-down:
    @cd services/gogs && docker compose down

# Restart the container (also reloads app.ini)
gogs-restart:
    @cd services/gogs && docker compose restart

# Follow container logs (Ctrl-C to exit)
gogs-logs:
    @cd services/gogs && docker compose logs --tail=100 -f

# Container state
gogs-ps:
    @cd services/gogs && docker compose ps

# Alias of gogs-ps
gogs-status: gogs-ps

# Render and validate the compose config
gogs-config:
    @cd services/gogs && docker compose config

# First-run setup: create the data dir and seed app.ini from the template
gogs-init:
    @cd services/gogs && { [ -f .env ] || { echo "missing services/gogs/.env — run: just bootstrap"; exit 1; }; } && \
    set -a && . ./.env && set +a && \
    mkdir -p "$GOGS_DATA_DIR/gogs/conf" "$GOGS_DATA_DIR/gogs/data" && \
    if [ ! -f "$GOGS_DATA_DIR/gogs/conf/app.ini" ]; then cp app.ini "$GOGS_DATA_DIR/gogs/conf/app.ini" && echo "seeded app.ini -> $GOGS_DATA_DIR/gogs/conf/"; else echo "app.ini already present in $GOGS_DATA_DIR/gogs/conf/"; fi && \
    echo "data dir ready: $GOGS_DATA_DIR — on Linux VM run: just gogs-chown (then just gogs-up)"

# Runs an alpine helper as root inside docker, so no host sudo is needed.
# Linux VM only: chown the host data dir to the container user (UID/GID 1000).
gogs-chown:
    @cd services/gogs && { [ -f .env ] || { echo "missing services/gogs/.env — run: just bootstrap"; exit 1; }; } && \
    set -a && . ./.env && set +a && \
    { [ -d "$GOGS_DATA_DIR" ] || { echo "data dir missing — run: just gogs-init"; exit 1; }; } && \
    case "$GOGS_DATA_DIR" in /*) host_dir="$GOGS_DATA_DIR" ;; *) host_dir="$(pwd)/$GOGS_DATA_DIR" ;; esac && \
    echo "chowning $host_dir to UID/GID 1000 (container user) ..." && \
    docker run --rm -v "$host_dir":/d alpine chown -R 1000:1000 /d && \
    echo "done — now run: just gogs-up"

# Open a shell inside the container
gogs-shell:
    @cd services/gogs && docker compose exec gogs sh

# Backup: stop -> tar the data dir -> start -> prune old backups
gogs-backup:
    @cd services/gogs && { [ -f .env ] || { echo "missing services/gogs/.env — run: just bootstrap"; exit 1; }; } && \
    set -a && . ./.env && set +a && \
    docker compose stop && \
    mkdir -p "$GOGS_BACKUP_DIR" && \
    stamp="$(date +%Y%m%d-%H%M%S)" && \
    tar -czf "$GOGS_BACKUP_DIR/gogs-$stamp.tar.gz" -C "$GOGS_DATA_DIR" . && \
    docker compose start && \
    echo "backup created: $GOGS_BACKUP_DIR/gogs-$stamp.tar.gz" && \
    keep=$((GOGS_BACKUP_KEEP + 1)) && \
    ls -1t "$GOGS_BACKUP_DIR"/gogs-*.tar.gz 2>/dev/null | tail -n +"$keep" | while read -r old; do rm -f -- "$old"; done && \
    echo "retention: keeping the latest $GOGS_BACKUP_KEEP backups"

# Restore from a backup archive (previous data is kept aside, not deleted)
gogs-restore file:
    @test -f "{{ file }}" || { echo "backup file not found: {{ file }}"; exit 1; }; \
    file_abs="$(cd "$(dirname "{{ file }}")" && pwd)/$(basename "{{ file }}")" && \
    cd services/gogs && { [ -f .env ] || { echo "missing services/gogs/.env — run: just bootstrap"; exit 1; }; } && \
    set -a && . ./.env && set +a && \
    docker compose stop && \
    if [ -d "$GOGS_DATA_DIR" ]; then old="$GOGS_DATA_DIR.old-$(date +%Y%m%d-%H%M%S)"; mv "$GOGS_DATA_DIR" "$old" && echo "previous data kept at: $old"; fi && \
    mkdir -p "$GOGS_DATA_DIR" && \
    tar -xzf "$file_abs" -C "$GOGS_DATA_DIR" && \
    docker compose start && \
    echo "restored from {{ file }}"

# Upgrade: bump the image tag in compose.yaml first, then run this (backs up, pulls, recreates)
gogs-update: gogs-backup
    @cd services/gogs && docker compose pull && docker compose up -d --force-recreate && echo "gogs recreated from the tag pinned in compose.yaml — record it in the README changelog"

# Container data in $GOGS_DATA_DIR is KEPT. To also wipe data: back up first,
# then remove data/gogs manually (destructive).
# Cleanup: stop + remove container/network and ALL cached gogs images (re-pulled on next up)
gogs-clean:
    @cd services/gogs && { [ -f .env ] || { echo "missing services/gogs/.env — run: just bootstrap"; exit 1; }; } && \
    set -a && . ./.env && set +a && \
    docker compose down && \
    docker image prune -f >/dev/null 2>&1; \
    n=0; \
    for img in $(docker images gogs/gogs -q); do docker image rm -f "$img" >/dev/null 2>&1 && n=$((n + 1)); done; \
    echo "cleanup done — removed $n gogs image(s); next 'just gogs-up' will pull the pinned tag"; \
    echo "container data kept at: $GOGS_DATA_DIR (wipe manually only after a backup)"
