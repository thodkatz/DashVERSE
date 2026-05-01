# DashVERSE Developer Notes

## Requirements

- OpenTofu (1.6+) or Terraform (1.6+)
- kubectl (1.28+)
- helm (3.0+)
- minikube (1.30+)
- Docker or Podman
- Ansible (2.9+)

If you have Nix installed, all dependencies are provided via `nix develop`.

<details>
<summary>
    Links for the requirements
</summary>

### Python

<https://www.python.org/downloads>

### Pyenv (optional)

Pyenv allows developers to install multiple versions of Python distribution and easy switching between the installed versions.

Website: <https://github.com/pyenv/pyenv?tab=readme-ov-file#installation>

### Poetry (optional)

Poetry is used for dependency management of the Python packages.

<https://python-poetry.org/docs/#installation>

### Podman

<https://podman.io/docs/installation>

### Docker

<https://docs.docker.com/engine/install>

### minikube

<https://minikube.sigs.k8s.io/docs/start>

### helm

<https://helm.sh/docs/intro/install>

</details>

## Deployment configurations

The deployment settings for both local (testing) and production environments can be found in `terraform/environments` folder.

## Deployment

### Quick Start

1. Start minikube

**Note:** If you already have a kubernetes cluster, you can skip this step.

```shell
minikube start --cpus='4' --memory='4g'
```

1. Deploy

   ```shell
   just deploy env=local
   ```

1. Verify pods are running

   ```shell
   just status
   ```

1. Access services

On a `separate terminal` do port forwarding to be able to access the service

```shell
just port-forward
```

1. Deploy preconfigured dashboards

   ```shell
   just setup-dashboards env=local
   ```

Then open:

- Superset: http://localhost:8088
- PostgREST API: http://localhost:3000
- PostgREST API Docs: http://localhost:3001
- Auth Service: http://localhost:8000
- Auth Service API Docs: http://localhost:8001
- Demo Portal: http://localhost:8080

### Credentials

Service credentials are auto-generated during deployment and stored securely in Kubernetes secrets. To retrieve them:

```shell
just show-access
```

This displays:

- PostgreSQL connection details
- Superset admin login

You can also retrieve individual credentials with kubectl:

```shell
# PostgreSQL password
kubectl get secret dashverse-secrets -n dashverse -o jsonpath='{.data.postgres-password}' | base64 -d

# Superset admin password
kubectl get secret dashverse-secrets -n dashverse -o jsonpath='{.data.superset-admin-password}' | base64 -d
```

### Justfile Recipes

| Target                  | Description                               |
| ----------------------- | ----------------------------------------- |
| `just deploy`           | Build images and deploy all services      |
| `just destroy`          | Remove all services                       |
| `just status`           | Show deployment status                    |
| `just port-forward`     | Forward ports to localhost                |
| `just logs`             | Tail all service logs                     |
| `just logs-auth`        | Tail auth service logs                    |
| `just sync`             | Download EVERSE indicators/dimensions     |
| `just sync-apply`       | Download and import to database           |
| `just sync-trigger`     | Trigger sync cronjob manually             |
| `just jwt`              | Generate JWT token (CLI)                  |
| `just build-auth`       | Build auth-service image                  |
| `just setup-dashboards` | Configure Superset dashboards via Ansible |
| `just seed-data`        | Import sample software and assessments    |

### Manual Deployment

```shell
cd terraform
tofu init
tofu apply -var-file="environments/local.tfvars"
```

### Production Deployment

```shell
# Deploy all services (builds images and applies Terraform)
just deploy env=production

# Populate data
just sync-apply
just seed-data

# Configure Superset dashboards
just setup-dashboards env=production
```

The production configuration (`terraform/environments/production.tfvars`) includes settings for external URLs used in iframe embedding.

### Sync EVERSE Data

Indicators and dimensions are synced from the EVERSE repository:
https://github.com/EVERSE-ResearchSoftware/indicators

The sync runs automatically daily at 2am via a CronJob. To trigger manually:

```shell
just sync-trigger
```

Or to sync outside the cluster:

```shell
just sync-apply
```

### Authentication

The Auth Service provides a web interface for user registration and JWT token generation.

1. Open http://localhost:8000 (after port-forward)
2. Register a new account
3. Login and generate an API token
4. Use the token for PostgREST write access

Alternatively, generate a token via CLI (register a user first):

```shell
just jwt <username> <password>
```

### API Documentation

Interactive API documentation is provided using [Scalar](https://scalar.com/):

- **PostgREST API Docs**: http://localhost:3001 - Database REST interface with all available endpoints
- **Auth Service API Docs**: http://localhost:8001 - Authentication endpoints for user management and JWT tokens

The documentation is automatically generated from OpenAPI specifications and includes an interactive request builder.

### Dashboard Configuration

After deployment, configure Superset with pre-built dashboards using Ansible:

```shell
just setup-dashboards
```

This creates five role-based dashboards based on [RSQKit roles](https://everse.software/RSQKit/your_role):

- **[Policy Maker](https://everse.software/RSQKit/policy_maker)** - High-level adoption and compliance overview
- **[Principal Investigator](https://everse.software/RSQKit/principal_investigator)** - Project-level metrics and action items
- **[Research Software Engineer](https://everse.software/RSQKit/research_software_engineer)** - Technical metrics and detailed check results
- **[Researcher Who Codes](https://everse.software/RSQKit/researcher_who_codes)** - Practical guidance and quick improvements
- **[Trainer](https://everse.software/RSQKit/trainer)** - Training insights and best practices

Prerequisites:

- Ansible (2.9+)
- Port forwarding running (`just port-forward`)
- Superset accessible at localhost:8088

The Superset admin password is automatically retrieved from Kubernetes secrets during setup.

### Sample Data

To populate the system with sample software and assessments for testing:

```shell
just seed-data
```

This fetches software metadata from the EVERSE TechRadar repository and generates sample assessments. The data will appear in the Superset dashboards.

## Documentation

- `docs/README.dev.md` – **Developer Notes**: Instructions on configuration and deployment
- `docs/architecture/README.md` – **System Architecture**: Detailed diagrams of the system, data flow, and security model.
- `docs/Deployment.md` – deployment checklist and prerequisites.
- `docs/Kubernetes.md` – operational commands for managing the Minikube deployment.
- `docs/Database.md` – details of the PostgreSQL schema, assessment mapping, and populate script usage.
- `docs/API_examples.md` – practical PostgREST calls, including the multi-step workflow for creating assessments.

## Clean up

Remove all deployed resources:

```shell
just destroy
```

Delete the minikube cluster:

```shell
minikube stop
minikube delete
```
