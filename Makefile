.PHONY: deploy destroy status port-forward logs logs-auth logs-demo clean sync sync-apply jwt build-auth build-demo setup-dashboards seed-data show-access

ENV ?= local
NS ?= dashverse
SYNC_DIR ?= /tmp/everse-sync

deploy: build-auth build-demo
	cd terraform && tofu init && tofu apply -var-file="environments/$(ENV).tfvars" -auto-approve

destroy:
	cd terraform && tofu destroy -var-file="environments/$(ENV).tfvars" -auto-approve

destroy-all: destroy
	minikube delete --all

status:
	kubectl get all -n $(NS)

port-forward:
	@trap 'kill 0' INT TERM; \
	kubectl port-forward -n $(NS) svc/postgresql 5432:5432 & \
	kubectl port-forward -n $(NS) svc/postgrest 3000:3000 & \
	kubectl port-forward -n $(NS) svc/superset 8088:8088 & \
	kubectl port-forward -n $(NS) svc/auth-service 8000:8000 & \
	kubectl port-forward -n $(NS) svc/demo-portal 8080:8080 & \
	kubectl port-forward -n $(NS) svc/postgrest-docs 3001:3001 & \
	kubectl port-forward -n $(NS) svc/auth-docs 8001:8001 & \
	wait

logs:
	kubectl logs -n $(NS) -l app=dashverse --all-containers -f

logs-postgres:
	kubectl logs -n $(NS) -l component=postgresql -f

logs-postgrest:
	kubectl logs -n $(NS) -l component=postgrest -f

logs-superset:
	kubectl logs -n $(NS) -l app.kubernetes.io/name=superset -f

logs-auth:
	kubectl logs -n $(NS) -l app=auth-service -f

clean:
	cd terraform && rm -rf .terraform .terraform.lock.hcl .tofu

sync:
	./scripts/sync-everse.sh $(SYNC_DIR)

sync-apply:
	./scripts/sync-everse.sh $(SYNC_DIR)
	./scripts/import-everse.sh $(SYNC_DIR) $(NS) --apply

sync-trigger:
	kubectl create job -n $(NS) --from=cronjob/everse-sync everse-sync-manual-$$(date +%s)

jwt:
	@if [ -z "$(USERNAME)" ] || [ -z "$(PASSWORD)" ]; then \
		echo "Usage: make jwt USERNAME=<user> PASSWORD=<pass>"; \
		echo "       Register a user first via http://localhost:8000/register"; \
		echo "       Auth-service must be reachable via 'make port-forward'"; \
		exit 1; \
	fi
	@curl -sf -X POST http://localhost:8000/api/auth/login \
		-H "Content-Type: application/json" \
		-d '{"username":"$(USERNAME)","password":"$(PASSWORD)"}' \
		| jq -r .access_token

build-auth:
ifeq ($(ENV),local)
	minikube image build -t dashverse/auth-service:latest auth-service/
else
	docker build -t dashverse/auth-service:latest auth-service/
endif

build-demo:
ifeq ($(ENV),local)
	minikube image build -t dashverse/demo-portal:latest demo-portal/
else
	docker build -t dashverse/demo-portal:latest demo-portal/
endif

logs-demo:
	kubectl logs -n $(NS) -l app=demo-portal -f

setup-dashboards:
	cd ansible && \
		DATABASE_PASSWORD=$$(kubectl get secret $(NS)-secrets -n $(NS) -o jsonpath='{.data.postgres-password}' | base64 -d) \
		SUPERSET_PASSWORD=$$(kubectl get secret $(NS)-secrets -n $(NS) -o jsonpath='{.data.superset-admin-password}' | base64 -d) \
		ansible-playbook -i inventory/$(ENV).yml playbooks/configure_superset.yml

seed-data:
	cd ansible && \
		ansible-playbook -i inventory/$(ENV).yml playbooks/seed_data.yml

show-access:
	@echo "=== DashVERSE credentials ==="
	@echo "PostgreSQL:"
	@echo "  user:     dashverse"
	@echo "  password: $$(kubectl get secret $(NS)-secrets -n $(NS) -o jsonpath='{.data.postgres-password}' | base64 -d)"
	@echo "  host:     postgresql.$(NS).svc.cluster.local:5432"
	@echo "  database: dashverse"
	@echo ""
	@echo "Superset:"
	@echo "  user:     admin"
	@echo "  password: $$(kubectl get secret $(NS)-secrets -n $(NS) -o jsonpath='{.data.superset-admin-password}' | base64 -d)"
	@echo "  url:      http://localhost:8088 (via 'make port-forward')"
