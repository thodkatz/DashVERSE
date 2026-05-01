# Database

PostgreSQL schema, views, and seed data used by PostgREST and Superset.

## Structure

- `sql/schema/` -- SQL files applied in numeric order during init
- `sql/data/` -- seed data loaded after schema creation

## Schema overview

Tables live in the `api` schema so PostgREST can expose them directly.
The `auth` schema is reserved for authentication tables.

## Deployment

The SQL schema files are loaded into Kubernetes as a ConfigMap by the
`db-init` Terraform module. PostgreSQL mounts the ConfigMap at
`/docker-entrypoint-initdb.d/` and runs the scripts in alphabetical order
on first startup.

To deploy:

```sh
just deploy env=local
```
