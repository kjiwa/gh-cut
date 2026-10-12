# Changelog

## 0.1.0

Cut a release with `gh cut <version>`: a version-bump pull request, a tag on the merged commit, and a GitHub release.

Wait for the pull request's checks, then merge with the repository's own merge method and without `--admin`, so GitHub signs the commit.

Read the release notes from the matching `CHANGELOG.md` section, with headings written as `## X.Y.Z` or `## [X.Y.Z] - date`.

Support prerelease versions such as `1.0.0-rc.1`, which mark the GitHub release as a prerelease.

Add `--dry-run`, which applies the bump, runs every check, discards the bump, and prints each mutating command.

Add `gh cut check` and `gh cut notes` for publish workflows and release-note extraction.

Load optional repository hooks from `scripts/release-hooks.sh`; without them the tag is the version and no bump pull request is made.
