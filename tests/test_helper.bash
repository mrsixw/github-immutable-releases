#!/usr/bin/env bash
# Provide isolated mock GitHub state and assertions for the Bats test suite.

setup_test_environment() {
    export TOOL="${BATS_TEST_DIRNAME}/../manage_immutable_releases.sh"
    export MOCK_GH_LOG="${BATS_TEST_TMPDIR}/gh.log"
    export MOCK_REPOS_FILE="${BATS_TEST_TMPDIR}/repositories"
    export MOCK_STATE_DIR="${BATS_TEST_TMPDIR}/states"
    export PATH="${BATS_TEST_DIRNAME}/helpers:${PATH}"

    mkdir -p "${MOCK_STATE_DIR}"
    : >"${MOCK_GH_LOG}"
    : >"${MOCK_REPOS_FILE}"

    unset MOCK_AUTH_FAIL
    unset MOCK_DISCOVERY_FAIL
    unset MOCK_MUTATION_FAIL_REPO
    unset MOCK_STATE_FAIL_REPO
    unset MOCK_VERIFY_FAIL_REPO
}

add_repository() {
    local repository="$1"
    local enabled="${2:-false}"
    local enforced="${3:-false}"

    printf '%s\n' "${repository}" >>"${MOCK_REPOS_FILE}"
    printf '%s\t%s\n' "${enabled}" "${enforced}" >"${MOCK_STATE_DIR}/${repository}"
}

assert_output_contains() {
    local expected="$1"

    # shellcheck disable=SC2154  # Bats populates output after each run command.
    if [[ "${output}" != *"${expected}"* ]]; then
        printf 'Expected output to contain: %s\nActual output:\n%s\n' \
            "${expected}" "${output}" >&2
        return 1
    fi
}

assert_log_contains() {
    local expected="$1"

    if ! grep -F -- "${expected}" "${MOCK_GH_LOG}" >/dev/null; then
        printf 'Expected gh log to contain: %s\nActual log:\n' "${expected}" >&2
        cat "${MOCK_GH_LOG}" >&2
        return 1
    fi
}

assert_log_excludes() {
    local unexpected="$1"

    if grep -F -- "${unexpected}" "${MOCK_GH_LOG}" >/dev/null; then
        printf 'Expected gh log not to contain: %s\nActual log:\n' "${unexpected}" >&2
        cat "${MOCK_GH_LOG}" >&2
        return 1
    fi
}

assert_repository_state() {
    local repository="$1"
    local expected="$2"
    local actual

    actual="$(cat "${MOCK_STATE_DIR}/${repository}")"
    [[ "${actual}" == "${expected}" ]]
}
