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
case $1 in
  release) [ "$2" = view ] && exit 1 ;;
esac
exit 0
EOF
  chmod +x "$WORK/bin/gh"
  PATH="$WORK/bin:$PATH"
  export PATH

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

_test_missing_hook_fails() {
  mv scripts/release-hooks.sh scripts/hooks.bak
  if "$GH_CUT" --dry-run 0.1.3 >/dev/null 2>&1; then
    _fail "missing hooks file was accepted"
  fi
  mv scripts/hooks.bak scripts/release-hooks.sh
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

main() {
  GH_CUT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/gh-cut
  readonly GH_CUT
  _setup
  _test_nested_tag_is_not_a_match
  _test_existing_tag_is_rejected
  _test_dry_run_leaves_tree_clean
  _test_missing_hook_fails
  _test_check_and_notes
  echo "ok"
}

main "$@"
