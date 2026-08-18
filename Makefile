.PHONY: help check phase1-db-up phase1-db-down

help:
	@printf '%s\n' \
		'Available targets:' \
		'  make check           Verify the local DevOps toolchain' \
		'  make phase1-db-up    Start the Phase 1 MySQL container' \
		'  make phase1-db-down  Stop MySQL and preserve its data'

check:
	@bash scripts/check-prerequisites.sh

phase1-db-up:
	@bash scripts/start-phase1-mysql.sh

phase1-db-down:
	@bash scripts/stop-phase1-mysql.sh
