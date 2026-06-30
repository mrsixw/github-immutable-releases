#!/usr/bin/env bats
# Exercise repository discovery, dry runs, mutations, and failure handling.

load test_helper

setup() {
    setup_test_environment
}

@test "help does not require authentication" {
    export MOCK_AUTH_FAIL=true

    run "${TOOL}" --help

    [ "${status}" -eq 0 ]
    assert_output_contains "The script is always a dry run"
    [ ! -s "${MOCK_GH_LOG}" ]
}

@test "enable and disable are mutually exclusive" {
    run "${TOOL}" --org example-org --pattern 'service-*' --enable --disable

    [ "${status}" -eq 2 ]
    assert_output_contains "--enable and --disable cannot be used together"
}

@test "an exact repository name produces one dry-run plan" {
    add_repository "service-api" false false
    add_repository "service-web" false false

    run "${TOOL}" --org example-org --pattern service-api --enable

    [ "${status}" -eq 0 ]
    assert_output_contains "Mode: DRY RUN"
    assert_output_contains "Matched repositories: 1"
    assert_output_contains "Before: enabled=false, enforced_by_owner=false"
    assert_output_contains "Would enable immutable releases; no mutation performed."
    assert_output_contains "Summary: matched=1 changed=0 unchanged=0 planned=1 failed=0"
    assert_log_excludes "--paginate"
    assert_log_excludes "--method PUT"
    assert_repository_state "service-api" $'false\tfalse'
}

@test "a glob reports discovery progress before processing matches" {
    add_repository "service-api" false false
    add_repository "service-web" false false
    add_repository "library" false false

    run "${TOOL}" --org example-org --pattern 'service-*' --enable

    [ "${status}" -eq 0 ]
    assert_output_contains "Discovering repositories in example-org (100 per API page)"
    assert_output_contains "Fetched page 1: 3 repositories (3 of 1000 limit retained)."
    assert_output_contains "Repository discovery complete: 3 repositories scanned."
    assert_output_contains "Matched repositories: 2"
    assert_output_contains "Summary: matched=2 changed=0 unchanged=0 planned=2 failed=0"
    assert_log_contains "page=1"
}

@test "glob discovery reports progress across multiple pages" {
    local index=1
    local repository

    while (( index <= 101 )); do
        printf -v repository 'service-%03d' "${index}"
        add_repository "${repository}" false false
        index=$((index + 1))
    done

    run "${TOOL}" --org example-org --pattern 'service-*' --enable

    [ "${status}" -eq 0 ]
    assert_output_contains "Fetched page 1: 100 repositories (100 of 1000 limit retained)."
    assert_output_contains "Fetched page 2: 1 repositories (101 of 1000 limit retained)."
    assert_output_contains "Summary: matched=101 changed=0 unchanged=0 planned=101 failed=0"
    assert_log_contains "page=2"
}

@test "a configured repository limit stops discovery with a warning" {
    add_repository "service-001" false false
    add_repository "service-002" false false
    add_repository "service-003" false false

    run "${TOOL}" --org example-org --pattern 'service-*' --limit 2 --enable

    [ "${status}" -eq 0 ]
    assert_output_contains "Repository limit 2 reached; additional repositories may exist."
    assert_output_contains "Matched repositories: 2"
    assert_output_contains "Summary: matched=2 changed=0 unchanged=0 planned=2 failed=0"
    [[ "${output}" != *"📦 [3/"* ]]
}

@test "zero and non-numeric repository limits are rejected" {
    run "${TOOL}" --org example-org --pattern 'service-*' --limit 0 --enable
    [ "${status}" -eq 2 ]
    assert_output_contains "--limit must be a positive integer"

    run "${TOOL}" --org example-org --pattern 'service-*' --limit unlimited --enable
    [ "${status}" -eq 2 ]
    assert_output_contains "--limit must be a positive integer"
}

@test "a limit above 1000 discovers repositories on later pages" {
    local index=1
    local repository

    while (( index <= 1000 )); do
        printf 'library-%04d\n' "${index}" >>"${MOCK_REPOS_FILE}"
        index=$((index + 1))
    done
    add_repository "service-target" false false

    run "${TOOL}" --org example-org --pattern 'service-*' --limit 1001 --enable

    [ "${status}" -eq 0 ]
    assert_output_contains "Fetched page 11: 1 repositories (1001 of 1001 limit retained)."
    assert_output_contains "Repository discovery complete: 1001 repositories scanned."
    assert_output_contains "Matched repositories: 1"
    assert_log_contains "page=11"
}

@test "no matches returns a failure without reading repository state" {
    add_repository "library" false false

    run "${TOOL}" --org example-org --pattern 'service-*' --enable

    [ "${status}" -eq 1 ]
    assert_output_contains "no repositories matched"
    assert_log_excludes "immutable-releases"
}

@test "kimi mode enables and verifies immutable releases" {
    add_repository "service-api" false false

    run "${TOOL}" --org example-org --pattern service-api --enable --kimi-mode

    [ "${status}" -eq 0 ]
    assert_output_contains "Mode: LIVE"
    assert_output_contains "After: enabled=true, enforced_by_owner=false"
    assert_output_contains "Passed: change confirmed."
    assert_log_contains "--method PUT"
    assert_repository_state "service-api" $'true\tfalse'
}

@test "the long live flag disables and verifies immutable releases" {
    add_repository "service-api" true false

    run "${TOOL}" --org example-org --pattern service-api --disable \
        --yes-yes-yes-i-know-what-im-doing

    [ "${status}" -eq 0 ]
    assert_output_contains "Mode: LIVE"
    assert_output_contains "After: enabled=false, enforced_by_owner=false"
    assert_log_contains "--method DELETE"
    assert_repository_state "service-api" $'false\tfalse'
}

@test "a repository already in the requested state is not mutated" {
    add_repository "service-api" true false

    run "${TOOL}" --org example-org --pattern service-api --enable --kimi-mode

    [ "${status}" -eq 0 ]
    assert_output_contains "already in the requested state"
    assert_output_contains "Summary: matched=1 changed=0 unchanged=1 planned=0 failed=0"
    assert_log_excludes "--method PUT"
}

@test "owner enforcement blocks repository-level disabling" {
    add_repository "service-api" true true

    run "${TOOL}" --org example-org --pattern service-api --disable --kimi-mode

    [ "${status}" -eq 1 ]
    assert_output_contains "cannot disable a setting enforced by the repository owner"
    assert_output_contains "failed=1"
    assert_log_excludes "--method DELETE"
}

@test "a per-repository read failure does not stop later repositories" {
    add_repository "service-broken" false false
    add_repository "service-good" false false
    export MOCK_STATE_FAIL_REPO="service-broken"

    run "${TOOL}" --org example-org --pattern 'service-*' --enable --kimi-mode

    [ "${status}" -eq 1 ]
    assert_output_contains "service-broken"
    assert_output_contains "service-good"
    assert_output_contains "Summary: matched=2 changed=1 unchanged=0 planned=0 failed=1"
    assert_repository_state "service-good" $'true\tfalse'
}

@test "a verification mismatch is reported as a failure" {
    add_repository "service-api" false false
    export MOCK_VERIFY_FAIL_REPO="service-api"

    run "${TOOL}" --org example-org --pattern service-api --enable --kimi-mode

    [ "${status}" -eq 1 ]
    assert_output_contains "After: enabled=false, enforced_by_owner=false"
    assert_output_contains "verification did not observe the requested state"
    assert_output_contains "failed=1"
}

@test "forced colour highlights unchanged, passed, and failed outcomes" {
    add_repository "service-api" true false
    export FORCE_COLOR=1

    run "${TOOL}" --org example-org --pattern service-api --enable
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\033[33m⏭️'* ]]

    printf 'false\tfalse\n' >"${MOCK_STATE_DIR}/service-api"
    run "${TOOL}" --org example-org --pattern service-api --enable --kimi-mode
    [ "${status}" -eq 0 ]
    [[ "${output}" == *$'\033[32m✅   Passed'* ]]

    printf 'false\tfalse\n' >"${MOCK_STATE_DIR}/service-api"
    export MOCK_VERIFY_FAIL_REPO="service-api"
    run "${TOOL}" --org example-org --pattern service-api --enable --kimi-mode
    [ "${status}" -eq 1 ]
    [[ "${output}" == *$'\033[31m❌   Failed'* ]]
}

@test "NO_COLOR suppresses ANSI colour codes" {
    add_repository "service-api" true false
    export FORCE_COLOR=1
    export NO_COLOR=1

    run "${TOOL}" --org example-org --pattern service-api --enable

    [ "${status}" -eq 0 ]
    [[ "${output}" != *$'\033['* ]]
    assert_output_contains "⏭️"
}

@test "authentication and discovery failures return an error" {
    export MOCK_AUTH_FAIL=true
    run "${TOOL}" --org example-org --pattern service-api --enable
    [ "${status}" -eq 1 ]
    assert_output_contains "not authenticated"

    export MOCK_AUTH_FAIL=false
    export MOCK_DISCOVERY_FAIL=true
    run "${TOOL}" --org example-org --pattern service-api --enable
    [ "${status}" -eq 1 ]
    assert_output_contains "failed to discover repositories"
}
