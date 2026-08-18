.PHONY: help check phase1-db-up phase1-db-down phase1-test phase1-run phase1-verify phase2-up phase2-down phase2-logs phase2-verify phase3-cluster-create phase3-manifests phase3-deploy phase3-status phase3-logs phase3-stop

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make check                 Verify the local DevOps toolchain' \
		'  make phase1-db-up          Start the Phase 1 MySQL container' \
		'  make phase1-db-down        Stop MySQL and preserve its data' \
		'  make phase1-test           Run Phase 1 unit tests' \
		'  make phase1-run            Run Flask with local .env values' \
		'  make phase1-verify         Run the full Phase 1 acceptance test' \
		'  make phase2-up             Build and start the Phase 2 stack' \
		'  make phase2-down           Stop Phase 2 without deleting data' \
		'  make phase2-logs           Follow Phase 2 service logs' \
		'  make phase2-verify         Run the full Phase 2 acceptance test' \
		'  make phase3-cluster-create Create or start the Phase 3 cluster and ingress controller' \
		'  make phase3-manifests      Validate the Phase 3 Helm manifests without deploying' \
		'  make phase3-deploy         Build, import, and deploy the Phase 3 application' \
		'  make phase3-status         Show Phase 3 Pods, Services, Ingress, and PVC' \
		'  make phase3-logs           Follow the Phase 3 backend logs' \
		'  make phase3-stop           Stop k3d while preserving the cluster and PVC'

check:
	@bash scripts/check-prerequisites.sh

phase1-db-up:
	@bash scripts/start-phase1-mysql.sh

phase1-db-down:
	@bash scripts/stop-phase1-mysql.sh

phase1-test:
	@.venv/bin/python -m pytest app/backend/tests -v

phase1-run:
	@set -a; . ./.env; set +a; .venv/bin/python app/backend/app.py

phase1-verify:
	@bash scripts/verify-phase1.sh

phase2-up:
	@docker compose --env-file .env -f deploy/compose/docker-compose.yml up -d --build --wait
	@curl --fail --silent http://127.0.0.1:8080/readyz >/dev/null

phase2-down:
	@docker compose --env-file .env -f deploy/compose/docker-compose.yml down

phase2-logs:
	@docker compose --env-file .env -f deploy/compose/docker-compose.yml logs --follow

phase2-verify:
	@bash scripts/verify-phase2.sh

phase3-cluster-create:
	@bash scripts/create-phase3-cluster.sh

phase3-manifests:
	@bash scripts/check-phase3-manifests.sh

phase3-deploy:
	@bash scripts/deploy-phase3.sh

phase3-status:
	@kubectl get pods,svc,ingress,pvc -n devops-platform

phase3-logs:
	@kubectl logs -n devops-platform deployment/devops-platform-devops-web-platform-backend --follow

phase3-stop:
	@bash scripts/stop-phase3.sh
