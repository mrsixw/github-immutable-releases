# Run local syntax, ShellCheck, and Bats validation. Use `make check` for all checks.

SHELL_SOURCES := manage_immutable_releases.sh tests/helpers/gh tests/test_helper.bash

.PHONY: check lint test

check: lint test

lint:
	bash -n $(SHELL_SOURCES)
	shellcheck $(SHELL_SOURCES)

test:
	bats tests
