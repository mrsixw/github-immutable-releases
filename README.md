# GitHub Immutable Releases

[![CI][ci-badge]][ci-workflow]

Manage GitHub immutable-release settings across repositories selected by
organization and repository-name pattern. The script reads and displays each
repository's current state before taking any action and verifies every live
change with a second API read.

The safe default is a dry run. Live changes require an explicit opt-in flag.

## Requirements

- Bash
- [GitHub CLI][github-cli]
- Authentication to GitHub.com through `gh auth login` or a supported token
  environment variable

No external JSON processor is required; JSON filtering uses GitHub CLI's
built-in `--jq` support.

## Usage

Preview enabling immutable releases for every matching repository:

```bash
./manage_immutable_releases.sh \
    --org example-org \
    --pattern 'service-*' \
    --enable
```

Preview disabling the setting for one exact repository:

```bash
./manage_immutable_releases.sh \
    --org example-org \
    --pattern service-api \
    --disable
```

Run the same operation live by adding either explicit opt-in flag:

```bash
./manage_immutable_releases.sh \
    --org example-org \
    --pattern 'service-*' \
    --enable \
    --kimi-mode
```

The deliberately verbose alias is also accepted:

```text
--yes-yes-yes-i-know-what-im-doing
```

### Example dry-run output

This exact repository lookup was run with:

```bash
NO_COLOR=1 ./manage_immutable_releases.sh \
    --org mrsixw \
    --pattern github-immutable-releases \
    --enable
```

```text
🚦 Mode: DRY RUN
🏢 Organization: mrsixw
🎯 Pattern: github-immutable-releases
📚 Repository limit: 1000
🔐 Requested state: enabled=true

🔎 Looking up exact repository mrsixw/github-immutable-releases...
✅ Exact repository found.
✅ Matched repositories: 1

📦 [1/1] mrsixw/github-immutable-releases
ℹ️    Before: enabled=false, enforced_by_owner=false
🧪   Would enable immutable releases; no mutation performed.

✅ Summary: matched=1 changed=0 unchanged=0 planned=1 failed=0
```

Always quote patterns containing glob metacharacters so the local shell does
not expand them before the script receives them. Supported matching follows
Bash shell-glob rules. A repository name without metacharacters is an exact
match.

Glob discovery fetches at most 1,000 repositories by default, ordered by full
name. Change the positive total cap with `--limit COUNT`; values above 1,000
are supported when an organization is larger. Exact repository lookups do not
enumerate the organization. GitHub's
[organization repositories endpoint][organization-repositories-api] returns a
maximum of 100 repositories per page, so the script displays progress as each
page arrives.

## Behaviour

For every matching repository, the script:

1. Reads and prints `enabled` and `enforced_by_owner`.
2. Reports the proposed operation in dry-run mode, or performs it in live mode.
3. Skips repositories already in the requested state.
4. Re-reads the state after a live mutation and verifies the result.
5. Continues processing after individual failures and returns a summary.

Interactive output uses green `✅` messages for successful changes, red `❌`
messages for failures, yellow `⏭️` or `⚠️` messages for unchanged states and
warnings, and progress icons during discovery. Set `NO_COLOR=1` to suppress
ANSI colours while retaining the status symbols.

Repository-level disabling is rejected when immutable releases are enforced by
the repository owner. The script returns a non-zero status if discovery fails,
no repositories match, any repository operation fails, or verification does
not observe the requested state.

Disabling immutable releases does not make releases created while the setting
was enabled mutable again. Existing releases also remain mutable when the
setting is first enabled unless they are republished. See GitHub's
[immutable-releases announcement][immutable-releases-announcement].

## Permissions

The authenticated identity must be able to see every intended repository. The
immutable-release status and mutation endpoints additionally require repository
administrator access.

| Operation | Fine-grained repository permission | Repository role |
| --- | --- | --- |
| Discover repositories | Metadata: read | Read access |
| Read status or perform a dry run | Administration: read | Administrator |
| Enable or disable | Administration: write | Administrator |

For a fine-grained personal access token, select the target repositories and
grant Administration read for dry runs or Administration write for live use.
Metadata read access is included with repository access. See GitHub's
[fine-grained token documentation][fine-grained-tokens].

For a classic personal access token, use `public_repo` when all targets are
public, or `repo` when private or internal repositories are included. The token
owner must still have administrator access to each target. Organizations using
SAML single sign-on may also require the token to be explicitly
[authorized for SSO][sso-authorization].

Organization-administration permission is not required because the script uses
repository-level endpoints. Organization policy can nevertheless enforce the
setting and prevent repository-level disabling. Endpoint details are available
in GitHub's [repository API documentation][immutable-releases-api].

## Exit statuses

| Status | Meaning |
| --- | --- |
| `0` | Every matched repository was read and handled successfully |
| `1` | Authentication, discovery, repository processing, or verification failed |
| `2` | Command-line arguments were invalid |

## Development

Install [Bats][bats] and [ShellCheck][shellcheck], then run:

```bash
make check
```

Use `make lint` for Bash syntax and ShellCheck, or `make test` for the Bats
suite alone.

The Bats suite places a mock `gh` executable first in `PATH`; it never contacts
GitHub or mutates real repositories. GitHub Actions runs the same syntax, lint,
and test checks for pull requests and changes to `main`.

## License

Released under the MIT License. See `LICENSE`.

---

[bats]: https://github.com/bats-core/bats-core
[ci-badge]: https://github.com/mrsixw/github-immutable-releases/actions/workflows/ci.yml/badge.svg
[ci-workflow]: https://github.com/mrsixw/github-immutable-releases/actions/workflows/ci.yml
[fine-grained-tokens]: https://docs.github.com/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
[github-cli]: https://cli.github.com/
[immutable-releases-announcement]: https://github.blog/changelog/2025-10-28-immutable-releases-are-now-generally-available/
[immutable-releases-api]: https://docs.github.com/rest/repos/repos?apiVersion=2026-03-10#check-if-immutable-releases-are-enabled-for-a-repository
[organization-repositories-api]: https://docs.github.com/rest/repos/repos?apiVersion=2026-03-10#list-organization-repositories
[shellcheck]: https://www.shellcheck.net/
[sso-authorization]: https://docs.github.com/authentication/authenticating-with-single-sign-on/authorizing-a-personal-access-token-for-use-with-single-sign-on
