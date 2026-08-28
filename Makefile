.PHONY: help check phase1-db-up phase1-db-down phase1-test phase1-run phase1-verify phase2-up phase2-down phase2-logs phase2-verify phase3-cluster-create phase3-manifests phase3-deploy phase3-status phase3-logs phase3-stop phase3-verify phase4-jenkins-build phase4-jenkins-up phase4-jenkins-logs phase4-jenkins-stop phase4-kubeconfig phase4-contract phase4-verify phase5-contract phase5-grafana-secret phase5-install phase5-prometheus phase5-grafana phase5-alertmanager phase5-status phase5-verify phase6-contract phase6-verify

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
		'  make phase3-stop           Stop k3d while preserving the cluster and PVC' \
		'  make phase3-verify         Run Phase 3 recovery and persistence acceptance' \
		'  make phase4-jenkins-build  Build the pinned Jenkins controller image' \
		'  make phase4-jenkins-up     Start Jenkins and preserve Jenkins Home' \
		'  make phase4-jenkins-logs   Follow Jenkins controller logs' \
		'  make phase4-jenkins-stop   Stop Jenkins without deleting Jenkins Home' \
		'  make phase4-kubeconfig     Generate and validate the scoped Jenkins kubeconfig' \
		'  make phase4-contract       Check Phase 4 files without deploying' \
		'  make phase4-verify         Run live Phase 4 delivery and restart acceptance' \
		'  make phase5-contract       Check Phase 5 monitoring resources without deploying' \
		'  make phase5-grafana-secret Create or rotate the local Grafana admin Secret' \
		'  make phase5-install        Install the pinned trimmed monitoring stack' \
		'  make phase5-prometheus     Open Prometheus safely on 127.0.0.1:9090' \
		'  make phase5-grafana        Open Grafana safely on 127.0.0.1:3000' \
		'  make phase5-alertmanager   Open Alertmanager safely on 127.0.0.1:9093' \
		'  make phase5-status         Show monitoring and application status without Secrets' \
		'  make phase5-verify         Run real Firing-to-Resolved alert acceptance' \
		'  make phase6-contract       Check Phase 6 failure-drill safety contracts' \
		'  make phase6-verify         Verify recovery, persistence, and monitoring'

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

phase3-verify:
	@bash scripts/verify-phase3.sh

phase4-jenkins-build:
	@docker compose -f deploy/jenkins/compose.yaml build

phase4-jenkins-up:
	@docker compose -f deploy/jenkins/compose.yaml up -d --wait

phase4-jenkins-logs:
	@docker compose -f deploy/jenkins/compose.yaml logs --follow

phase4-jenkins-stop:
	@docker compose -f deploy/jenkins/compose.yaml stop

phase4-kubeconfig:
	@bash scripts/create-phase4-kubeconfig.sh

phase4-contract:
	@bash scripts/check-phase4-contract.sh

phase4-verify:
	@bash scripts/verify-phase4.sh

phase5-contract:
	@bash scripts/check-phase5-contract.sh

phase5-grafana-secret:
	@bash scripts/create-phase5-grafana-secret.sh

phase5-install:
	@bash scripts/install-phase5-monitoring.sh

phase5-prometheus:
	@bash scripts/phase5-port-forward.sh prometheus

phase5-grafana:
	@bash scripts/phase5-port-forward.sh grafana

phase5-alertmanager:
	@bash scripts/phase5-port-forward.sh alertmanager

phase5-status:
	@bash scripts/phase5-status.sh

phase5-verify:
	@bash scripts/verify-phase5.sh

phase6-contract:
	@bash scripts/check-phase6-contract.sh

phase6-verify:
	@bash scripts/verify-phase6.sh
