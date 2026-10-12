# gh-cut

A `gh` extension that cuts a release: a version-bump pull request, a tag on the
merged commit, and a GitHub release built from the matching `CHANGELOG.md` section.

```sh
gh extension install kjiwa/gh-cut
gh cut [--dry-run] <version>       # 0.1.8, not v0.1.8
gh cut check <tag> [<title>]       # tag shape, version, title, CHANGELOG heading
gh cut check --changelog <tag>
gh cut notes <version>             # print the CHANGELOG section
```

Run from a clean `main` that matches `origin/main`. `--dry-run` applies the bump,
runs every check, discards the bump, and prints each mutating command.

## Repository hooks

`scripts/release-hooks.sh` is sourced by gh-cut and defines:

- `release_version`: print the current version; fail if versioned files disagree.
- `release_bump VERSION`: write VERSION into every versioned file (and lockfiles).
- `release_checks`: run the gates a release must pass.

Set `RELEASE_BY_WORKFLOW=1` when a workflow, not gh-cut, creates the GitHub release
from the pushed tag.

## Development

```sh
shellcheck gh-cut tests/test.sh && sh tests/test.sh
```
