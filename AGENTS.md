# AGENTS.md — conventions for the tofu repository

## What this repo is

- A **homelab service management** repository, not an application codebase: it commits service declarations and docs only — never data or secrets.
- One self-contained directory per service under `services/<name>/`: `compose.yaml` + `.env.example` + service config template (e.g. `app.ini`) + `README.md` (ops manual).
- Design-doc-first: every service gets `docs/<name>-design.md` before implementation.
- Managed via **just** (single command entrypoint); **pi agent** assists with repo content, config and runbooks.

## Project structure (first level)

```
tofu/
├── services/          # one dir per service (compose/.env.example/config template/README)
├── docs/              # design docs: docs/<name>-design.md (+ index)
├── .pi/               # pi skills/prompts shared with the repo (whitelisted in .gitignore)
├── .github/           # CI workflow
├── data/              # one gitignored umbrella for runtime data + backups:
│                      #   data/<service>/          container data
│                      #   data/backups/<service>/  backups
├── AGENTS.md          # this file — conventions & boundaries
├── justfile           # single command entrypoint
├── README.md
├── dprint.json        # formatting config (md/toml/json, pinned wasm plugins)
└── .gitignore
```

## Tech stack & environment

- Toolchain direction: **Rust + TS** (no TS yet; **no Python toolchain**).
- Formatting: **dprint** (`dprint.json`; plugins pinned by wasm URL) — md/toml/json now; TS via a dprint plugin later, Rust via `cargo fmt`/`clippy`.
- Task runner: **just** (CI pins `just-version`; keep local just aligned — `just check` is the source of truth).
- Runtime: **docker compose v2**. Production = a Linux VM; test = macOS (Docker Desktop). The repo is cloned on both; differences live only in the local `.env` and `data/` (one umbrella for runtime data + backups).

## Common commands (dev machine)

```bash
just --list                    # list all recipes
just bootstrap                 # create missing .env from .env.example (idempotent)
just doctor                    # environment self-check (dprint/docker/just)
just fmt                       # format repo files (dprint)
just check                     # format checks (dprint + justfile self-check) — must be green
just ci                        # CI aggregate entrypoint
just <service>-<action>        # service-level ops (run only inside services/<service>/)
```

Tool install: `npm i -g dprint@0.57.1` (or brew/cargo); docker + docker compose.

## Git boundaries (strict)

- Never create or switch branches (`git checkout`/`switch`/`branch`/`rebase`) without explicit owner approval. Work on the current branch only.
- Owner approval required before executing a plan or any multi-step change; creating/updating a plan or design doc is exempt, executing it is not.
- Owner approval required before `git commit`. All changes stay in the working tree for review first.
- **Never push.** Push is performed manually by the owner; human code review is required before push.

## Conventions

- **Language**: committed content is in **English** by default; only `*-draft.md` files (local AI collaboration notes) may use other languages, are gitignored, and **must not be referenced by committed docs**. Commit messages in English (conventional commits: `type(scope): summary`).
- **Secrets only in `.env`** (gitignored): never in compose/docs/AGENTS. Only `.env.example` is committed.
- **Config layering**: deploy-layer values (ports, paths) in `.env`/compose; application-layer config (e.g. Gogs `app.ini`) lives in the service data dir, templated in the repo with `${ENV}` injection (see `docs/gogs-design.md`).
- **Design-doc-first**: new service → `docs/<name>-design.md` reviewed before implementation; every change updates the service `README.md`.
- **Format gate**: `just check` must be green; GitHub Actions `.github/workflows/ci.yml` runs `just check` (dprint + justfile self-format).
- **Keep tables narrow**: if a markdown table's rows would render wider than about 110 columns, put only a short summary in the table and explain details in a list right below it.

## Working with pi agent

- Read `docs/<name>-design.md` and the service `README.md` before touching a service.
- Use `/skill:code-review` (`.pi/skills/code-review`) for review passes; do not rely on the reviewer loop alone.
- **Docker boundary**: the agent environment is not guaranteed docker access. Deployment/backup/upgrade/verification that requires docker is **executed by the dev/owner on the target machine** (mac test or Linux VM). The agent prepares/updates declarations and runbooks — never fabricate execution results.
- Verification: prefer HTTP/DOM/config checks over screenshots (models often cannot read images).

## Environment tips

- If fetching external resources fails, use the proxy env vars (`$https_proxy`/`$http_proxy`) or `http://127.0.0.1:1095`.
- Local drafts: files matching `*-draft.md` are ephemeral AI collaboration notes — never committed and never referenced from committed documentation (see `.gitignore`).
