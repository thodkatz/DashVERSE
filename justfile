# DashVERSE task runner
#
# Usage:        just <recipe> [args]
# List recipes: just --list
# Override var: just env=production <recipe>     (assignment BEFORE recipe name)

env := "local"
ns := "dashverse"

# Show available recipes
default:
    @just --list

# Build images and deploy all services
deploy: build-auth build-landing
    cd terraform && tofu init && tofu apply -var-file="environments/{{env}}.tfvars" -auto-approve

# Remove all deployed services
destroy:
    cd terraform && tofu destroy -var-file="environments/{{env}}.tfvars" -auto-approve

# Destroy services and delete the minikube cluster
destroy-all: destroy
    minikube delete --all

# Show deployment status
status:
    kubectl get all -n {{ns}}

# Forward all service ports to localhost (Ctrl+C to stop)
port-forward:
    @trap 'kill 0' INT TERM; \
    kubectl port-forward -n {{ns}} svc/postgresql 5432:5432 & \
    kubectl port-forward -n {{ns}} svc/postgrest 3000:3000 & \
    kubectl port-forward -n {{ns}} svc/superset 8088:8088 & \
    kubectl port-forward -n {{ns}} svc/auth-service 8000:8000 & \
    kubectl port-forward -n {{ns}} svc/landing 8080:8080 & \
    kubectl port-forward -n {{ns}} svc/postgrest-docs 3001:3001 & \
    kubectl port-forward -n {{ns}} svc/auth-docs 8001:8001 & \
    wait

# Tail all service logs
logs:
    kubectl logs -n {{ns}} -l app=dashverse --all-containers -f

# Tail PostgreSQL logs
logs-postgres:
    kubectl logs -n {{ns}} -l component=postgresql -f

# Tail PostgREST logs
logs-postgrest:
    kubectl logs -n {{ns}} -l component=postgrest -f

# Tail Superset logs
logs-superset:
    kubectl logs -n {{ns}} -l app.kubernetes.io/name=superset -f

# Tail auth-service logs
logs-auth:
    kubectl logs -n {{ns}} -l app=auth-service -f

# Tail landing logs
logs-landing:
    kubectl logs -n {{ns}} -l app=landing -f

# Remove terraform state and lock files
clean:
    cd terraform && rm -rf .terraform .terraform.lock.hcl .tofu

# Download EVERSE indicators and dimensions (no DB apply)
sync:
    cd ansible && \
        ansible-playbook -i inventory/{{env}}.yml playbooks/sync_everse.yml --tags fetch

# Download and import EVERSE indicators/dimensions to database
sync-apply:
    cd ansible && \
        ansible-playbook -i inventory/{{env}}.yml playbooks/sync_everse.yml

# Trigger the in-cluster sync cronjob manually
sync-trigger:
    kubectl create job -n {{ns}} --from=cronjob/everse-sync everse-sync-manual-$(date +%s)

# Generate a JWT (auth-service must be reachable via 'just port-forward')
# Register a user first at http://localhost:8000/register
jwt username password:
    @curl -sSf -X POST http://localhost:8000/api/auth/login \
        -H "Content-Type: application/json" \
        -d '{"username":"{{username}}","password":"{{password}}"}' \
        | jq -r .access_token

# Build the auth-service image
build-auth:
    if [ "{{env}}" = "local" ]; then \
        minikube image build -t dashverse/auth-service:latest auth-service/; \
    else \
        docker build -t dashverse/auth-service:latest auth-service/; \
    fi

# Build the landing image
build-landing:
    if [ "{{env}}" = "local" ]; then \
        minikube image build -t dashverse/landing:latest landing/; \
    else \
        docker build -t dashverse/landing:latest landing/; \
    fi

# Configure Superset dashboards via Ansible
setup-dashboards:
    cd ansible && \
    DATABASE_PASSWORD=$(kubectl get secret {{ns}}-secrets -n {{ns}} -o jsonpath='{.data.postgres-password}' | base64 -d) \
    SUPERSET_PASSWORD=$(kubectl get secret {{ns}}-secrets -n {{ns}} -o jsonpath='{.data.superset-admin-password}' | base64 -d) \
    ansible-playbook -i inventory/{{env}}.yml playbooks/configure_superset.yml

# Import sample assessment data
seed-data:
    cd ansible && \
        ansible-playbook -i inventory/{{env}}.yml playbooks/seed_data.yml

# Show service credentials
show-access:
    @echo "=== DashVERSE credentials ==="
    @echo "PostgreSQL:"
    @echo "  user:     dashverse"
    @echo "  password: $(kubectl get secret {{ns}}-secrets -n {{ns}} -o jsonpath='{.data.postgres-password}' | base64 -d)"
    @echo "  host:     postgresql.{{ns}}.svc.cluster.local:5432"
    @echo "  database: dashverse"
    @echo ""
    @echo "Superset:"
    @echo "  user:     admin"
    @echo "  password: $(kubectl get secret {{ns}}-secrets -n {{ns}} -o jsonpath='{.data.superset-admin-password}' | base64 -d)"
    @echo "  url:      http://localhost:8088 (via 'just port-forward')"
