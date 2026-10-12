# gh-cut

A `gh` extension that cuts a release: a version-bump pull request, a signed merge, a tag on the merged commit, and a GitHub release built from your `CHANGELOG.md`.

```text
$ gh cut --dry-run 0.1.3
From origin
 * branch            main       -> FETCH_HEAD
+ release_bump 0.1.3
+ git -C . switch -c release-0.1.3
+ git -C . add -u
+ git -C . commit -m Release 0.1.3
+ git -C . push -u origin release-0.1.3
+ git -C . switch main
+ gh pr create --base main --head release-0.1.3 --title 'Release 0.1.3'
+ gh pr checks <pr-url> --watch --fail-fast
+ gh pr merge <pr-url> --squash --delete-branch --match-head-commit <branch-head>
+ git -C . pull --ff-only origin main
+ git -C . tag -a v0.1.3 -m v0.1.3
+ git -C . push origin v0.1.3
+ gh release create v0.1.3 --title v0.1.3 --notes-file <## 0.1.3 CHANGELOG section> --verify-tag
```

`--dry-run` applies the bump, runs every check, discards the bump, and prints each mutating command. The transcript replaces the repository path with `.`; real output shows the absolute path.

## When to use it

Use gh-cut when you write `CHANGELOG.md` by hand and want a release from one local command with no extra token.

- release-please and semantic-release derive the version and notes from commit messages. gh-cut takes the version you type and the notes you wrote.
- gh-ship bumps the version in a workflow, and by its own docs a release PR authored by the default `GITHUB_TOKEN` does not run CI, so it asks for a GitHub App token or PAT. gh-cut bumps locally and opens the PR as you, so the checks you already require run as usual.

## Install

```sh
gh extension install kjiwa/gh-cut
gh extension install kjiwa/gh-cut --pin v0.1.0   # fixed release
```

## Requirements

- `gh`, authenticated, and `git`.
- POSIX `sh`.
- A clean default branch that matches `origin`.
- Required PR checks on the default branch. gh-cut merges only after the PR's checks pass.

## Usage

```sh
gh cut [--dry-run] <version>       # 0.1.8, not v0.1.8
gh cut check <tag> [<title>]       # tag shape, version, title, CHANGELOG heading
gh cut check --changelog <tag>
gh cut notes <version>             # print the CHANGELOG section
```

`<version>` may carry a prerelease suffix (`1.0.0-rc.1`), which marks the GitHub release as a prerelease.

## Flow

1. Check that the `CHANGELOG.md` heading exists, the branch is the default branch, the tree is clean, the default branch matches `origin`, and the tag and release do not exist.
2. Run `release_bump`, then the checks, and commit on `release-<version>`.
3. Push the branch and open a PR.
4. Wait for the PR's checks.
5. Merge with the repository's merge method (squash, then merge, then rebase) and delete the branch. gh-cut does not use `--admin`, so GitHub signs the merge commit.
6. Fast-forward the default branch.
7. Tag the merge commit and push the tag.
8. Create the GitHub release from the `CHANGELOG.md` section.

If the version on the default branch already reads `<version>`, steps 2 to 6 are skipped.

`CHANGELOG.md` headings read `## X.Y.Z` or `## [X.Y.Z] - date`.

## Hooks

`scripts/release-hooks.sh` is sourced with the repository root as the working directory and defines:

- `release_version`: print the current version; fail if versioned files disagree.
- `release_bump VERSION`: write VERSION into every versioned file and lockfile.
- `release_checks`: run the gates a release must pass. Defaults to a no-op.

Define `release_version` and `release_bump` together or not at all. Set `RELEASE_BY_WORKFLOW=1` when a workflow, not gh-cut, creates the GitHub release from the pushed tag.

Python, version in `pyproject.toml`:

```sh
release_version() {
  sed -n 's/^version = "\(.*\)"$/\1/p' pyproject.toml
}

release_bump() {
  sed 's/^version = ".*"$/version = "'"$1"'"/' pyproject.toml >pyproject.toml.new
  mv pyproject.toml.new pyproject.toml
}
```

npm, version in `package.json`:

```sh
release_version() {
  node -p "require('./package.json').version"
}

release_bump() {
  npm version "$1" --no-git-tag-version
}
```

No hooks: omit `scripts/release-hooks.sh`. The tag is the version, no bump PR is made, and gh-cut tags the current commit and creates the release.

## Publish workflow

Verify the tag against the version and `CHANGELOG.md` before publishing:

```yaml
on:
  push:
    tags: ["v*"]
jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - run: gh extension install kjiwa/gh-cut
        env:
          GH_TOKEN: ${{ github.token }}
      - run: gh cut check "$TAG" "$TAG"
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ github.ref_name }}
```

## Development

```sh
shellcheck gh-cut tests/test.sh && sh tests/test.sh
```
