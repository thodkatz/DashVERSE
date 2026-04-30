A minimal deployment using only docker.

# Usage

```shell
cp .env.example .env                                          # (edit if you want real secrets)
docker compose up -d --build                                  # bring everything up
docker compose logs -f superset-init                          # wait until "Bootstrap complete" appears, ~1-2 min
docker compose --profile setup run --rm setup-dashboards      # provision charts/dashboards
```
