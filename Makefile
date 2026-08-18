.PHONY: help check

help:
	@printf '%s\n' 'Available targets:' '  make check  Verify the local DevOps toolchain'

check:
	@bash scripts/check-prerequisites.sh
