#!/usr/bin/env bash
# Manage immutable release settings for GitHub repositories selected by name.
# Usage: manage_immutable_releases.sh --org ORG --pattern GLOB (--enable|--disable) [LIVE_FLAG]

set -u
set -o pipefail

readonly API_HOST="github.com"
readonly API_VERSION="2026-03-10"

ORG=""
PATTERN=""
ACTION=""
LIVE_MODE=false

usage() {
    cat <<'EOF'
Usage:
  manage_immutable_releases.sh --org ORG --pattern GLOB (--enable|--disable) [LIVE_FLAG]

Options:
  --org ORG       GitHub organization containing the repositories.
  --pattern GLOB  Shell glob matched against repository names. A name without
                  glob metacharacters is an exact match.
  --enable        Enable immutable releases on matching repositories.
  --disable       Disable immutable releases on matching repositories.
  --kimi-mode     Perform live mutations instead of the default dry run.
  --yes-yes-yes-i-know-what-im-doing
                  Alias for --kimi-mode.
  -h, --help      Show this help text.

The script is always a dry run unless a live-mode flag is provided.
EOF
}

usage_error() {
    printf 'Error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

set_action() {
    local requested_action="$1"

    if [[ -n "${ACTION}" && "${ACTION}" != "${requested_action}" ]]; then
        usage_error "--enable and --disable cannot be used together"
    fi

    ACTION="${requested_action}"
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --org)
                (( $# >= 2 )) || usage_error "--org requires a value"
                ORG="$2"
                shift 2
                ;;
            --pattern)
                (( $# >= 2 )) || usage_error "--pattern requires a value"
                PATTERN="$2"
                shift 2
                ;;
            --enable)
                set_action "enable"
                shift
                ;;
            --disable)
                set_action "disable"
                shift
                ;;
            # 🏎️ Leave dry-run mode alone unless you know what you're doing.
            --kimi-mode|--yes-yes-yes-i-know-what-im-doing)
                LIVE_MODE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage_error "unknown argument: $1"
                ;;
        esac
    done

    [[ -n "${ORG}" ]] || usage_error "--org is required"
    [[ "${ORG}" != */* ]] || usage_error "--org must not contain a slash"
    [[ -n "${PATTERN}" ]] || usage_error "--pattern is required"
    [[ "${PATTERN}" != */* ]] || usage_error "--pattern must match repository names, not paths"
    [[ -n "${ACTION}" ]] || usage_error "exactly one of --enable or --disable is required"
}

check_prerequisites() {
    if ! command -v gh >/dev/null 2>&1; then
        printf 'Error: GitHub CLI (gh) is required.\n' >&2
        exit 1
    fi

    if ! gh auth status --hostname "${API_HOST}" >/dev/null 2>&1; then
        printf 'Error: GitHub CLI is not authenticated for %s.\n' "${API_HOST}" >&2
        exit 1
    fi
}

github_api() {
    gh api \
        --hostname "${API_HOST}" \
        -H 'Accept: application/vnd.github+json' \
        -H "X-GitHub-Api-Version: ${API_VERSION}" \
        "$@"
}

discover_repositories() {
    if [[ "${PATTERN}" != *'*'* && "${PATTERN}" != *'?'* && "${PATTERN}" != *'['* ]]; then
        github_api \
            "repos/${ORG}/${PATTERN}" \
            --jq '.name'
        return
    fi

    github_api \
        --paginate \
        "orgs/${ORG}/repos?per_page=100&type=all&sort=full_name&direction=asc" \
        --jq '.[].name'
}

read_immutable_state() {
    local repository="$1"

    github_api \
        "repos/${ORG}/${repository}/immutable-releases" \
        --jq '[.enabled, (.enforced_by_owner // false)] | @tsv'
}

parse_state() {
    local state="$1"
    local enabled_var="$2"
    local enforced_var="$3"
    local enabled
    local enforced

    IFS=$'\t' read -r enabled enforced <<<"${state}"
    if [[ "${enabled}" != "true" && "${enabled}" != "false" ]]; then
        return 1
    fi
    if [[ "${enforced}" != "true" && "${enforced}" != "false" ]]; then
        return 1
    fi

    printf -v "${enabled_var}" '%s' "${enabled}"
    printf -v "${enforced_var}" '%s' "${enforced}"
}

change_state() {
    local repository="$1"
    local method

    if [[ "${ACTION}" == "enable" ]]; then
        method="PUT"
    else
        method="DELETE"
    fi

    github_api \
        --method "${method}" \
        "repos/${ORG}/${repository}/immutable-releases" \
        >/dev/null
}

main() {
    local discovered_repositories
    local repository
    local before_state
    local before_enabled
    local before_enforced
    local after_state
    local after_enabled
    local after_enforced
    local desired_enabled
    local mode
    local index=0
    local changed=0
    local unchanged=0
    local planned=0
    local failed=0
    local -a matching_repositories=()

    parse_arguments "$@"
    check_prerequisites

    if [[ "${ACTION}" == "enable" ]]; then
        desired_enabled="true"
    else
        desired_enabled="false"
    fi

    if [[ "${LIVE_MODE}" == "true" ]]; then
        mode="LIVE"
    else
        mode="DRY RUN"
    fi

    printf 'Mode: %s\n' "${mode}"
    printf 'Organization: %s\n' "${ORG}"
    printf 'Pattern: %s\n' "${PATTERN}"
    printf 'Requested state: enabled=%s\n\n' "${desired_enabled}"

    if ! discovered_repositories="$(discover_repositories)"; then
        printf 'Error: failed to discover repositories in %s.\n' "${ORG}" >&2
        exit 1
    fi

    while IFS= read -r repository; do
        [[ -n "${repository}" ]] || continue
        # shellcheck disable=SC2053  # PATTERN intentionally uses shell-glob semantics.
        if [[ "${repository}" == ${PATTERN} ]]; then
            matching_repositories+=("${repository}")
        fi
    done <<<"${discovered_repositories}"

    if (( ${#matching_repositories[@]} == 0 )); then
        printf 'Error: no repositories matched %s in %s.\n' "${PATTERN}" "${ORG}" >&2
        exit 1
    fi

    printf 'Matched repositories: %d\n\n' "${#matching_repositories[@]}"

    for repository in "${matching_repositories[@]}"; do
        index=$((index + 1))
        printf '[%d/%d] %s/%s\n' \
            "${index}" "${#matching_repositories[@]}" "${ORG}" "${repository}"

        if ! before_state="$(read_immutable_state "${repository}")"; then
            printf '  Result: failed to read current state.\n\n' >&2
            failed=$((failed + 1))
            continue
        fi

        if ! parse_state "${before_state}" before_enabled before_enforced; then
            printf '  Result: API returned an invalid current state.\n\n' >&2
            failed=$((failed + 1))
            continue
        fi

        printf '  Before: enabled=%s, enforced_by_owner=%s\n' \
            "${before_enabled}" "${before_enforced}"

        if [[ "${before_enabled}" == "${desired_enabled}" ]]; then
            printf '  Result: already in the requested state; no change needed.\n\n'
            unchanged=$((unchanged + 1))
            continue
        fi

        if [[ "${ACTION}" == "disable" && "${before_enforced}" == "true" ]]; then
            printf '  Result: cannot disable a setting enforced by the repository owner.\n\n' >&2
            failed=$((failed + 1))
            continue
        fi

        if [[ "${LIVE_MODE}" != "true" ]]; then
            printf '  Would %s immutable releases; no mutation performed.\n\n' "${ACTION}"
            planned=$((planned + 1))
            continue
        fi

        printf '  Action: %s immutable releases.\n' "${ACTION}"
        if ! change_state "${repository}"; then
            printf '  Result: mutation failed.\n\n' >&2
            failed=$((failed + 1))
            continue
        fi

        if ! after_state="$(read_immutable_state "${repository}")"; then
            printf '  Result: mutation completed, but verification read failed.\n\n' >&2
            failed=$((failed + 1))
            continue
        fi

        if ! parse_state "${after_state}" after_enabled after_enforced; then
            printf '  Result: API returned an invalid verification state.\n\n' >&2
            failed=$((failed + 1))
            continue
        fi

        printf '  After: enabled=%s, enforced_by_owner=%s\n' \
            "${after_enabled}" "${after_enforced}"

        if [[ "${after_enabled}" != "${desired_enabled}" ]]; then
            printf '  Result: verification failed; requested state was not observed.\n\n' >&2
            failed=$((failed + 1))
            continue
        fi

        printf '  Result: change confirmed.\n\n'
        changed=$((changed + 1))
    done

    printf 'Summary: matched=%d changed=%d unchanged=%d planned=%d failed=%d\n' \
        "${#matching_repositories[@]}" "${changed}" "${unchanged}" "${planned}" "${failed}"

    if (( failed > 0 )); then
        exit 1
    fi
}

main "$@"
