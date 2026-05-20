# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

DashVERSE is a dashboard prototype for the [EVERSE project](https://everse.software/), displaying research software quality assessments. The full stack runs on Kubernetes (Minikube for local/VM dev) and is provisioned entirely through OpenTofu (Terraform-compatible).

## Development Environment

All dependencies are available via Nix:

```sh
nix develop        # uses flake.nix — starts minikube automatically via shellHook
# or
nix-shell shell.nix
```

Non-Nix requirements: OpenTofu 1.6+, kubectl 1.28+, helm 3.0+, minikube 1.30+, Docker or Podman, Ansible 2.9+.

## Common Commands

```sh
# Deploy everything (builds images + tofu apply)
make deploy ENV=local          # ENV=production for prod

# Teardown
make destroy ENV=local

# Check pod status
make status

# Stream port-forward to localhost (keep running in a terminal)
make port-forward

# Seed sample data from EVERSE TechRadar
make seed-data

# Sync EVERSE indicators/dimensions from upstream repo
make sync-apply

# Configure Superset dashboards (requires port-forward running)
make setup-dashboards ENV=local

# Generate a JWT token
make jwt

# Rebuild only a specific image (into minikube for ENV=local)
make build-auth
make build-demo

# Logs
make logs            # all services
make logs-auth
make logs-superset
make logs-postgres
make logs-postgrest
make logs-demo

# Manual tofu workflow
cd terraform && tofu init && tofu apply -var-file="environments/local.tfvars"

# Trigger the sync CronJob inside the cluster
make sync-trigger
```

## Architecture

The entire infrastructure is defined as OpenTofu modules under `terraform/modules/`. Each module maps to one Kubernetes service. `terraform/main.tf` wires them together; `terraform/environments/` holds per-env `.tfvars`.

### Services and ports

| Service | Port | Module |
|---|---|---|
| PostgreSQL | 5432 | `modules/postgresql` |
| PostgREST (REST API) | 3000 | `modules/postgrest` |
| PostgREST API docs (Scalar) | 3001 | `modules/api-docs` |
| Apache Superset | 8088 | `modules/superset` (Helm) |
| Auth service | 8000 | `modules/auth-service` |
| Auth API docs (Scalar) | 8001 | `modules/api-docs` |
| Demo portal | 8083 | `modules/demo-portal` |

### Custom services

- **`auth-service/`** — FastAPI app (`auth-service/app/`). Issues JWT tokens for PostgREST write access. Built into Minikube with `make build-auth`.
- **`demo-portal/`** — FastAPI app (`demo-portal/app/`). Public-facing dashboard using Superset embeds. Built with `make build-demo`.
- **`database/`** — Python scripts for schema init and data population (`main.py`, `populate_data.py`). Not a running service; used for local DB scripting.

### Data model

All tables live in the `api` schema (PostgREST exposes this schema directly). Core tables: `software`, `dimensions`, `indicators`, `assessment_raw`. See [docs/Database.md](docs/Database.md) for full schema.

### Auth flow

PostgREST requires a JWT signed with the `jwt-secret` Kubernetes secret for write operations. The auth service handles user registration and token generation. Read-only PostgREST access requires no token.

### Dashboard configuration

Ansible (`ansible/`) automates Superset setup: creates datasources, datasets, and five role-based dashboards (Policy Maker, PI, RSE, Researcher, Trainer). It runs against `localhost:8088` so port-forward must be active.

### EVERSE data sync

`scripts/sync-everse.sh` fetches indicators/dimensions from `EVERSE-ResearchSoftware/indicators` on GitHub. `scripts/import-everse.sh` applies them to the database. A CronJob (`modules/sync`) runs this daily at 2am inside the cluster. Seed data comes from `EVERSE-ResearchSoftware/TechRadar` (`quality-tools/` path).

## VM Deployment (NixOS hypervisor)

For end-to-end testing on a headless Ubuntu VM hosted on a NixOS server, see [docs/VM.md](docs/VM.md).

Management scripts (run on the NixOS server):

```sh
bash scripts/vm/start.sh    # start VM + minikube + port-forward + SSH tunnels
bash scripts/vm/stop.sh     # stop everything (add --vm to also shut down the VM)
```


## Demo Data vs Real Data

Two distinct data categories exist in the database. Do not confuse them.

**Demo data** (TechRadar samples -- not real assessments):
- `software` table -- populated by `make seed-data` (fetches ~20 packages from EVERSE TechRadar) and previously by 4 hardcoded entries in `database/sql/data/003_software.sql` (now removed)
- `assessment_raw` table -- populated by `make seed-data` with synthetic check results

**Real reference data** (upstream EVERSE definitions):
- `indicators` and `dimensions` tables -- populated by `make sync-apply`, which pulls from the real `EVERSE-ResearchSoftware/indicators` GitHub repo. Do not treat these as demo data.

**Schema note:** `assessment_raw` and `software` have no foreign key relationship. `assessment_raw` stores everything as a JSONB blob. The tables are independent.

**DB credentials:** The PostgreSQL user and database are both `dashverse` (not `postgres`). Use `-U dashverse -d dashverse` in any `psql` invocation.

### Clean deployment (no demo data)

`scripts/vm/deploy-dashverse.sh` defaults to skipping seed data. Pass `--skip-seed` explicitly if you ever need to be certain, or just don't call `make seed-data` after deploy.

To wipe demo data from an already-running cluster:

```sh
make clear-demo-data   # TRUNCATEs assessment_raw and software, leaves indicators/dimensions intact
```

## Known Gotchas

### Dashboard views score everything as zero
The views in `database/sql/schema/006_create_views.sql` originally matched pass/fail using `status LIKE '%Pass%'`. All resqui plugins emit `schema:CompletedActionStatus` as the status URI regardless of outcome — the actual result is in the `output` field (`"true"` / `"false"` / `"error"`). The views were fixed to use `check_item->>'output' = 'true'` for pass detection. If scores ever show as zero again, check that the views haven't regressed.

### `indicators` table identifier must be the full IRI
`scripts/import-everse.sh` populates the `indicators` table. The identifier column must store the full `@id` IRI (e.g. `https://w3id.org/everse/i/indicators/software_has_license`) because the dashboard views join on `check_item->'assessesIndicator'->>'@id' = i.identifier`. An earlier version used the short `.abbreviation` field, causing all joins to miss. If the dashboards show data in "recent assessments" but zero scores, run the unmatched-IRI diagnostic query:

```sql
SELECT DISTINCT check_item->'assessesIndicator'->>'@id' AS indicator_iri
FROM assessment_raw
CROSS JOIN LATERAL jsonb_array_elements(payload->'checks') AS check_item
WHERE NOT EXISTS (
  SELECT 1 FROM api.indicators i
  WHERE i.identifier = check_item->'assessesIndicator'->>'@id'
);
```

If rows are returned, re-run `make sync-apply` (the script now correctly uses `$id`).

### `indicators` table is not cleared by `make clear-demo-data`
`clear-demo-data` only truncates `assessment_raw` and `software`. The `indicators` and `dimensions` tables survive. `make sync-apply` must be run at least once after a fresh deploy — it is not called automatically.

## Key Docs

- [docs/README.dev.md](docs/README.dev.md) — deployment walkthrough
- [docs/Database.md](docs/Database.md) — schema details
- [docs/API_examples.md](docs/API_examples.md) — PostgREST query examples and assessment workflow
- [docs/Kubernetes.md](docs/Kubernetes.md) — operational kubectl commands
- [docs/Superset.md](docs/Superset.md) — Superset-specific notes
