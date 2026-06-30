#!/usr/bin/env bash
# Manage immutable release settings for GitHub repositories selected by name.
# Usage: manage_immutable_releases.sh --org ORG --pattern GLOB (--enable|--disable) [LIVE_FLAG]

set -u
set -o pipefail

readonly API_HOST="github.com"
readonly API_VERSION="2026-03-10"
readonly API_MAX_ATTEMPTS="${API_MAX_ATTEMPTS:-3}"
readonly API_RETRY_DELAY_SECONDS="${API_RETRY_DELAY_SECONDS:-2}"

ORG=""
PATTERN=""
ACTION=""
LIVE_MODE=false
RED=""
GREEN=""
YELLOW=""
CYAN=""
BLUE=""
BOLD=""
RESET=""

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

setup_colors() {
    if [[ -n "${NO_COLOR:-}" ]]; then
        return
    fi

    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    BLUE=$'\033[34m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
}

print_progress() {
    printf '%s🔎 %s%s\n' "${CYAN}" "$*" "${RESET}" >&2
}

print_success() {
    printf '%s✅ %s%s\n' "${GREEN}" "$*" "${RESET}"
}

print_discovery_success() {
    printf '%s✅ %s%s\n' "${GREEN}" "$*" "${RESET}" >&2
}

print_failure() {
    printf '%s❌ %s%s\n' "${RED}" "$*" "${RESET}" >&2
}

print_warning() {
    printf '%s⚠️  %s%s\n' "${YELLOW}" "$*" "${RESET}" >&2
}

print_unchanged() {
    printf '%s⏭️  %s%s\n' "${YELLOW}" "$*" "${RESET}"
}

print_info() {
    printf '%sℹ️  %s%s\n' "${BLUE}" "$*" "${RESET}"
}

print_dry_run() {
    printf '%s🧪 %s%s\n' "${CYAN}" "$*" "${RESET}"
}

usage_error() {
    print_failure "Error: $1"
    printf '\n' >&2
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
        print_failure "Error: GitHub CLI (gh) is required."
        exit 1
    fi

    if ! gh auth status --hostname "${API_HOST}" >/dev/null 2>&1; then
        print_failure "Error: GitHub CLI is not authenticated for ${API_HOST}."
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

fetch_repository_page() {
    local page="$1"
    local attempt=1
    local repositories

    while (( attempt <= API_MAX_ATTEMPTS )); do
        if repositories="$(
            github_api \
                "orgs/${ORG}/repos?per_page=100&type=all&sort=full_name&direction=asc&page=${page}" \
                --jq '.[].name'
        )"; then
            printf '%s\n' "${repositories}"
            return 0
        fi

        if (( attempt == API_MAX_ATTEMPTS )); then
            return 1
        fi

        print_warning "Page ${page} fetch failed (attempt ${attempt}/${API_MAX_ATTEMPTS}); retrying in ${API_RETRY_DELAY_SECONDS}s."
        sleep "${API_RETRY_DELAY_SECONDS}"
        attempt=$((attempt + 1))
    done
}

discover_repositories() {
    local exact_repository
    local page_repositories
    local repository
    local page=1
    local page_count
    local total_count=0

    if [[ "${PATTERN}" != *'*'* && "${PATTERN}" != *'?'* && "${PATTERN}" != *'['* ]]; then
        print_progress "Looking up exact repository ${ORG}/${PATTERN}..."
        if ! exact_repository="$(
            github_api \
                "repos/${ORG}/${PATTERN}" \
                --jq '.name'
        )"; then
            return 1
        fi
        print_discovery_success "Exact repository found."
        printf '%s\n' "${exact_repository}"
        return 0
    fi

    print_progress "Discovering repositories in ${ORG} (100 per API page)..."
    while :; do
        if ! page_repositories="$(fetch_repository_page "${page}")"; then
            return 1
        fi

        page_count=0
        while IFS= read -r repository; do
            [[ -n "${repository}" ]] || continue
            page_count=$((page_count + 1))
            printf '%s\n' "${repository}"
            total_count=$((total_count + 1))
        done <<<"${page_repositories}"

        print_progress "Fetched page ${page}: ${page_count} repositories (${total_count} total)."

        if (( page_count < 100 )); then
            break
        fi
        page=$((page + 1))
    done

    print_discovery_success "Repository discovery complete: ${total_count} repositories scanned."
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

    setup_colors
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

    printf '%s🚦 Mode: %s%s\n' "${BOLD}" "${mode}" "${RESET}"
    printf '🏢 Organization: %s\n' "${ORG}"
    printf '🎯 Pattern: %s\n' "${PATTERN}"
    printf '🔐 Requested state: enabled=%s\n\n' "${desired_enabled}"

    if ! discovered_repositories="$(discover_repositories)"; then
        print_failure "Error: failed to discover repositories in ${ORG}."
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
        print_failure "Error: no repositories matched ${PATTERN} in ${ORG}."
        exit 1
    fi

    print_success "Matched repositories: ${#matching_repositories[@]}"
    printf '\n'

    for repository in "${matching_repositories[@]}"; do
        index=$((index + 1))
        printf '📦 [%d/%d] %s/%s\n' \
            "${index}" "${#matching_repositories[@]}" "${ORG}" "${repository}"

        if ! before_state="$(read_immutable_state "${repository}")"; then
            print_failure "  Failed: could not read current state."
            printf '\n'
            failed=$((failed + 1))
            continue
        fi

        if ! parse_state "${before_state}" before_enabled before_enforced; then
            print_failure "  Failed: API returned an invalid current state."
            printf '\n'
            failed=$((failed + 1))
            continue
        fi

        print_info "  Before: enabled=${before_enabled}, enforced_by_owner=${before_enforced}"

        if [[ "${before_enabled}" == "${desired_enabled}" ]]; then
            print_unchanged "  Unchanged: already in the requested state; no change needed."
            printf '\n'
            unchanged=$((unchanged + 1))
            continue
        fi

        if [[ "${ACTION}" == "disable" && "${before_enforced}" == "true" ]]; then
            print_failure "  Failed: cannot disable a setting enforced by the repository owner."
            printf '\n'
            failed=$((failed + 1))
            continue
        fi

        if [[ "${LIVE_MODE}" != "true" ]]; then
            print_dry_run "  Would ${ACTION} immutable releases; no mutation performed."
            printf '\n'
            planned=$((planned + 1))
            continue
        fi

        print_info "  Action: ${ACTION} immutable releases."
        if ! change_state "${repository}"; then
            print_failure "  Failed: mutation request failed."
            printf '\n'
            failed=$((failed + 1))
            continue
        fi

        if ! after_state="$(read_immutable_state "${repository}")"; then
            print_failure "  Failed: mutation completed, but verification read failed."
            printf '\n'
            failed=$((failed + 1))
            continue
        fi

        if ! parse_state "${after_state}" after_enabled after_enforced; then
            print_failure "  Failed: API returned an invalid verification state."
            printf '\n'
            failed=$((failed + 1))
            continue
        fi

        print_info "  After: enabled=${after_enabled}, enforced_by_owner=${after_enforced}"

        if [[ "${after_enabled}" != "${desired_enabled}" ]]; then
            print_failure "  Failed: verification did not observe the requested state."
            printf '\n'
            failed=$((failed + 1))
            continue
        fi

        print_success "  Passed: change confirmed."
        printf '\n'
        changed=$((changed + 1))
    done

    if (( failed > 0 )); then
        print_failure "Summary: matched=${#matching_repositories[@]} changed=${changed} unchanged=${unchanged} planned=${planned} failed=${failed}"
        exit 1
    fi
    print_success "Summary: matched=${#matching_repositories[@]} changed=${changed} unchanged=${unchanged} planned=${planned} failed=${failed}"
}

main "$@"
