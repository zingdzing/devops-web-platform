.PHONY: help check phase1-db-up phase1-db-down phase1-test phase1-run phase1-verify

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make check           Verify the local DevOps toolchain' \
		'  make phase1-db-up    Start the Phase 1 MySQL container' \
		'  make phase1-db-down  Stop MySQL and preserve its data' \
		'  make phase1-test     Run Phase 1 unit tests' \
		'  make phase1-run      Run Flask with local .env values' \
		'  make phase1-verify   Run the full Phase 1 acceptance test'

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
