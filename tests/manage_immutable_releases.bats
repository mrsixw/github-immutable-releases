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

@test "a glob matches every corresponding repository through paginated discovery" {
    add_repository "service-api" false false
    add_repository "service-web" false false
    add_repository "library" false false

    run "${TOOL}" --org example-org --pattern 'service-*' --enable

    [ "${status}" -eq 0 ]
    assert_output_contains "Matched repositories: 2"
    assert_output_contains "Summary: matched=2 changed=0 unchanged=0 planned=2 failed=0"
    assert_log_contains "--paginate"
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
    assert_output_contains "Result: change confirmed."
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
    assert_output_contains "verification failed"
    assert_output_contains "failed=1"
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
