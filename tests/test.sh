#!/bin/sh
# Exercises gh-cut against a throwaway repository with a bare origin and a
# stub gh on PATH.
set -eu

_fail() {
  echo "FAIL: $*" >&2
  exit 1
}

_setup() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-cut-test.XXXXXX")
  trap 'rm -rf "$WORK"' EXIT
  mkdir "$WORK/bin"
  cat >"$WORK/bin/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GH_STUB_LOG"
prev=
for arg in "$@"; do
  [ "$prev" = --notes-file ] && cat "$arg" >"$GH_STUB_LOG.notes"
  prev=$arg
done
case $1 in
  release) [ "$2" = view ] && exit 1 ;;
  repo)
    printf '%s\t%s\t%s\t%s\n' "${GH_STUB_BRANCH:-main}" "${GH_STUB_SQUASH:-true}" \
      "${GH_STUB_MERGE:-true}" "${GH_STUB_REBASE:-true}"
    ;;
esac
exit 0
EOF
  chmod +x "$WORK/bin/gh"
  PATH="$WORK/bin:$PATH"
  GH_STUB_LOG="$WORK/gh.log"
  export PATH GH_STUB_LOG

  git init -q --bare -b main "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
  cd "$WORK/repo"
  git config user.email t@example.com
  git config user.name t
  mkdir scripts
  printf '0.1.2\n' >VERSION
  printf '# Changelog\n\n## 0.1.3\n\nnotes for 0.1.3\n\n## 0.1.2\n\nolder\n' >CHANGELOG.md
  cat >scripts/release-hooks.sh <<'EOF'
release_version() { cat VERSION; }
release_bump() { printf '%s\n' "$1" >VERSION; }
release_checks() { :; }
EOF
  git add -A
  git commit -q -m init
  git push -q origin HEAD:main
  git branch -q --set-upstream-to=origin/main main
  BASE=$(git rev-parse HEAD)
}

_reset_to_base() {
  git reset -q --hard "$BASE"
  git clean -qfd
  git push -q -f origin "$BASE:refs/heads/main"
}

_commit_and_push() {
  git add -A
  git commit -q -m "$1"
  git push -q origin HEAD:main
}

_test_nested_tag_is_not_a_match() {
  git tag -a old/v0.1.3 -m old
  git push -q origin old/v0.1.3
  _test_out=$("$GH_CUT" --dry-run 0.1.3 2>&1) || _fail "old/v0.1.3 on origin blocked v0.1.3: $_test_out"
  git push -q origin :refs/tags/old/v0.1.3
  git tag -d old/v0.1.3 >/dev/null
}

_test_existing_tag_is_rejected() {
  git tag -a v0.1.3 -m v0.1.3
  git push -q origin v0.1.3
  if "$GH_CUT" --dry-run 0.1.3 >/dev/null 2>&1; then
    _fail "existing v0.1.3 on origin was not rejected"
  fi
  git push -q origin :refs/tags/v0.1.3
  git tag -d v0.1.3 >/dev/null
}

_test_dry_run_leaves_tree_clean() {
  "$GH_CUT" --dry-run 0.1.3 >/dev/null 2>&1 || _fail "dry run failed"
  [ -z "$(git status --porcelain)" ] || _fail "dry run left a dirty worktree"
  [ "$(cat VERSION)" = "0.1.2" ] || _fail "dry run changed VERSION"
}

_test_no_hooks_file_tags_and_releases() {
  git rm -q scripts/release-hooks.sh
  _commit_and_push "drop hooks"
  _test_out=$("$GH_CUT" --dry-run 0.1.3 2>&1) || _fail "dry run failed without a hooks file: $_test_out"
  case $_test_out in
    *"pr create"*) _fail "tag-only dry run opened a bump PR: $_test_out" ;;
  esac
  case $_test_out in
    *"tag -a v0.1.3"*"gh release create v0.1.3"*) ;;
    *) _fail "tag-only dry run did not tag and release: $_test_out" ;;
  esac
  _reset_to_base
}

_test_version_hook_without_bump_hook_fails() {
  printf 'release_version() { cat VERSION; }\n' >scripts/release-hooks.sh
  _commit_and_push "half hooks"
  if "$GH_CUT" --dry-run 0.1.3 >/dev/null 2>&1; then
    _fail "release_version without release_bump was accepted"
  fi
  _reset_to_base
}

_test_release_checks_see_the_bump() {
  cat >scripts/release-hooks.sh <<'EOF'
release_version() { cat VERSION; }
release_bump() { printf '%s\n' "$1" >VERSION; }
release_checks() { [ "$(cat VERSION)" = 0.1.3 ]; }
EOF
  _commit_and_push "checks assert the bump"
  _test_out=$("$GH_CUT" --dry-run 0.1.3 2>&1) || _fail "release_checks did not see the bumped tree: $_test_out"
  [ "$(cat VERSION)" = "0.1.2" ] || _fail "dry run left the bump behind"
  _reset_to_base
}

_test_bump_leftover_file_is_named() {
  cat >scripts/release-hooks.sh <<'EOF'
release_version() { cat VERSION; }
release_bump() { printf '%s\n' "$1" >VERSION; : >new.lock; }
release_checks() { :; }
EOF
  _commit_and_push "bump creates a file"
  if _test_out=$("$GH_CUT" --dry-run 0.1.3 2>&1); then
    _fail "bump that created an untracked file was accepted"
  fi
  case $_test_out in
    *new.lock*) ;;
    *) _fail "failure did not name new.lock: $_test_out" ;;
  esac
  _reset_to_base
}

_test_untracked_bump_leaves_no_branch() {
  cat >scripts/release-hooks.sh <<'EOF'
release_version() { cat VERSION; }
release_bump() { printf '%s\n' "$1" >VERSION; : >new.lock; }
release_checks() { :; }
EOF
  _commit_and_push "bump creates a file"
  if _test_out=$("$GH_CUT" 0.1.3 2>&1); then
    _fail "bump that created an untracked file was accepted"
  fi
  [ -z "$(git branch --list 'release-*')" ] || _fail "failed run left a release branch: $_test_out"
  rm -f new.lock
  [ -z "$(git status --porcelain)" ] || _fail "failed run left a dirty tree"
  _reset_to_base
}

_test_path_executable_is_not_a_hook() {
  git rm -q scripts/release-hooks.sh
  _commit_and_push "drop hooks"
  mkdir "$WORK/hookbin"
  printf '#!/bin/sh\necho 9.9.9\n' >"$WORK/hookbin/release_version"
  chmod +x "$WORK/hookbin/release_version"
  _test_out=$(PATH="$WORK/hookbin:$PATH" "$GH_CUT" --dry-run 0.1.3 2>&1) || _fail "PATH executable was treated as a hook: $_test_out"
  case $_test_out in
    *"tag -a v0.1.3"*) ;;
    *) _fail "tag-only path was not taken: $_test_out" ;;
  esac
  rm -rf "$WORK/hookbin"
  _reset_to_base
}

_test_bad_option_runs_no_hooks() {
  printf 'touch "%s/marker"\n' "$WORK" >scripts/release-hooks.sh
  _commit_and_push "marker hooks"
  _test_status=0
  "$GH_CUT" --bogus >/dev/null 2>&1 || _test_status=$?
  [ "$_test_status" -eq 2 ] || _fail "--bogus exited $_test_status, not 2"
  [ ! -e "$WORK/marker" ] || _fail "hooks ran before arguments were validated"
  _reset_to_base
}

_test_check_and_notes() {
  "$GH_CUT" check --changelog v0.1.3 || _fail "check --changelog rejected a present heading"
  if "$GH_CUT" check --changelog v9.9.9 >/dev/null 2>&1; then
    _fail "check --changelog accepted a missing heading"
  fi
  "$GH_CUT" check v0.1.2 v0.1.2 || _fail "check rejected a matching tag and title"
  if "$GH_CUT" check v0.1.2 v0.1.3 >/dev/null 2>&1; then
    _fail "check accepted a title that differs from the tag"
  fi
  if "$GH_CUT" check v0.1.3 >/dev/null 2>&1; then
    _fail "check accepted a tag that differs from the version"
  fi
  [ "$("$GH_CUT" notes 0.1.3)" = "
notes for 0.1.3" ] || _fail "notes printed the wrong section"
}

_test_help_works_outside_a_repo() {
  _test_out=$(cd "$WORK" && "$GH_CUT" --help 2>/dev/null) || _fail "--help failed outside a repo"
  case $_test_out in
    usage:*) ;;
    *) _fail "--help did not print usage to stdout: $_test_out" ;;
  esac
}

_test_notes_and_changelog_check_need_no_hooks() {
  mv scripts/release-hooks.sh scripts/hooks.bak
  "$GH_CUT" check --changelog v0.1.3 || _fail "check --changelog needed a hooks file"
  [ "$("$GH_CUT" notes 0.1.3)" = "
notes for 0.1.3" ] || _fail "notes needed a hooks file"
  mv scripts/hooks.bak scripts/release-hooks.sh
}

_test_default_branch_and_merge_method_come_from_the_repo() {
  git switch -q -c trunk
  git push -q origin trunk
  git branch -q --set-upstream-to=origin/trunk trunk
  _test_out=$(GH_STUB_BRANCH=trunk GH_STUB_SQUASH=false "$GH_CUT" --dry-run 0.1.3 2>&1) ||
    _fail "dry run failed on a trunk repo: $_test_out"
  case $_test_out in
    *"--base trunk"*"gh pr merge"*"--merge --delete-branch"*) ;;
    *) _fail "dry run did not use trunk and --merge: $_test_out" ;;
  esac
  git switch -q main
  git branch -q -D trunk
  git push -q origin :refs/heads/trunk
}

_test_changelog_heading_matches() {
  _test_title=$1
  _test_expect=$2
  printf '# Changelog\n\n%s\n\nbody\n' "$_test_title" >CHANGELOG.md
  if "$GH_CUT" check --changelog v0.1.3 >/dev/null 2>&1; then
    _test_got=match
  else
    _test_got=none
  fi
  [ "$_test_got" = "$_test_expect" ] || _fail "heading '$_test_title': expected $_test_expect, got $_test_got"
  git checkout -q -- CHANGELOG.md
}

_test_changelog_headings() {
  _test_changelog_heading_matches '## [0.1.3] - 2026-10-12' match
  _test_changelog_heading_matches '## 0.1.3' match
  _test_changelog_heading_matches '## 0.1.30' none
  _test_changelog_heading_matches '## 0x1x3' none
  printf '# Changelog\n\n## [0.1.3] - 2026-10-12\n\nbody\n\n## [0.1.2] - 2026-10-01\n\nolder\n' >CHANGELOG.md
  [ "$("$GH_CUT" notes 0.1.3)" = "
body" ] || _fail "notes did not read a Keep a Changelog section"
  git checkout -q -- CHANGELOG.md
}

_test_prerelease_and_verify_tag() {
  _test_out=$("$GH_CUT" --dry-run 0.1.3 2>&1) || _fail "dry run failed: $_test_out"
  case $_test_out in
    *"gh release create"*"--verify-tag"*) ;;
    *) _fail "release did not verify the tag: $_test_out" ;;
  esac
  case $_test_out in
    *--prerelease*) _fail "stable release was marked prerelease: $_test_out" ;;
  esac
  printf '# Changelog\n\n## 1.0.0-rc.1\n\nrc\n' >CHANGELOG.md
  _commit_and_push "rc changelog"
  _test_out=$("$GH_CUT" --dry-run 1.0.0-rc.1 2>&1) || _fail "prerelease dry run failed: $_test_out"
  case $_test_out in
    *"gh release create v1.0.0-rc.1"*"--prerelease"*) ;;
    *) _fail "prerelease was not marked: $_test_out" ;;
  esac
  _reset_to_base
}

_test_real_run_on_a_bumped_default_branch() {
  printf '0.1.3\n' >VERSION
  _commit_and_push "bump"
  : >"$GH_STUB_LOG"
  _test_out=$("$GH_CUT" 0.1.3 2>&1) || _fail "real run failed: $_test_out"
  [ -n "$(git ls-remote --tags origin refs/tags/v0.1.3)" ] || _fail "tag v0.1.3 is not on origin"
  grep -Fq 'release create v0.1.3 ' "$GH_STUB_LOG" || _fail "gh release create did not name the tag: $(cat "$GH_STUB_LOG")"
  grep -Fq -- '--verify-tag' "$GH_STUB_LOG" || _fail "gh release create lacked --verify-tag: $(cat "$GH_STUB_LOG")"
  [ "$(cat "$GH_STUB_LOG.notes")" = "
notes for 0.1.3" ] || _fail "release notes were wrong: $(cat "$GH_STUB_LOG.notes")"
  git push -q origin :refs/tags/v0.1.3
  git tag -d v0.1.3 >/dev/null
  _reset_to_base
}

_class_violations() {
  grep -En 'grep +(-[A-Za-z]+ +)*"\$' "$1" | grep -Ev 'grep +(-[A-Za-z]+ +)*-[A-Za-z]*F' || true
  # shellcheck disable=SC2016 # literal $ is the pattern
  sed 's/"\$CHANGELOG_AWK_LIB"//g' "$1" |
    grep -En "(awk|sed)( +-[A-Za-z-]+)* +\"[^\"]*\\$|'\"\\$" || true
}

_test_no_variable_patterns_in_gh_cut() {
  _test_bad=$(_class_violations "$GH_CUT")
  [ -z "$_test_bad" ] || _fail "variable used as a grep, awk, or sed pattern:
$_test_bad"
}

_test_class_check_catches_a_bad_copy() {
  # shellcheck disable=SC2016 # literal bad source lines
  printf '%s\n' 'grep -q "$x" f' 'grep -Fq "$x" f' 'awk "$prog" f' \
    "sed 's/a/'\"\$y\"'/' f" >"$WORK/bad.sh"
  [ "$(_class_violations "$WORK/bad.sh" | wc -l)" -eq 3 ] || _fail "class check missed a bad pattern: $(_class_violations "$WORK/bad.sh")"
}

main() {
  GH_CUT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/gh-cut
  readonly GH_CUT
  _setup
  _test_nested_tag_is_not_a_match
  _test_existing_tag_is_rejected
  _test_dry_run_leaves_tree_clean
  _test_no_hooks_file_tags_and_releases
  _test_version_hook_without_bump_hook_fails
  _test_release_checks_see_the_bump
  _test_bump_leftover_file_is_named
  _test_untracked_bump_leaves_no_branch
  _test_path_executable_is_not_a_hook
  _test_bad_option_runs_no_hooks
  _test_changelog_headings
  _test_prerelease_and_verify_tag
  _test_check_and_notes
  _test_help_works_outside_a_repo
  _test_notes_and_changelog_check_need_no_hooks
  _test_default_branch_and_merge_method_come_from_the_repo
  _test_real_run_on_a_bumped_default_branch
  _test_class_check_catches_a_bad_copy
  _test_no_variable_patterns_in_gh_cut
  echo "ok"
}

main "$@"
