#!/usr/bin/env bash
# Runs install.sh / remove.sh against throwaway HOME directories and asserts
# the resulting state. No framework: prints PASS/FAIL per check, exits 1 if
# any check failed.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0
FAILED=0

ok() {
  if eval "$1"; then
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL: %s\n' "${2:-$1}" >&2
    FAILED=$((FAILED + 1))
  fi
}

no() {
  if eval "$1"; then
    printf 'FAIL: %s\n' "${2:-not: $1}" >&2
    FAILED=$((FAILED + 1))
  else
    PASSED=$((PASSED + 1))
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    PASSED=$((PASSED + 1))
  else
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$2" "$1" >&2
    FAILED=$((FAILED + 1))
  fi
}

# contains HAYSTACK NEEDLE DESC — substring check that never eval's its input.
contains() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)) ;;
    *) printf 'FAIL: %s\n  looked for: %s\n  in: %s\n' "$3" "$2" "$1" >&2
       FAILED=$((FAILED + 1)) ;;
  esac
}

not_contains() {
  case "$1" in
    *"$2"*) printf 'FAIL: %s\n  unexpectedly found: %s\n' "$3" "$2" >&2
            FAILED=$((FAILED + 1)) ;;
    *) PASSED=$((PASSED + 1)) ;;
  esac
}

fake_home() {
  local h
  h="$(mktemp -d)"
  mkdir -p "${h}/.claude"
  printf '%s\n' "${h}"
}

run_install() {
  HOME="$1" bash "${REPO_DIR}/install.sh" >/dev/null 2>&1
}

run_remove() {
  HOME="$1" bash "${REPO_DIR}/remove.sh" >/dev/null 2>&1
}

# A PATH containing everything install.sh needs EXCEPT jq, so the preflight
# can be exercised without uninstalling anything.
path_without_jq() {
  local stub bin p
  stub="$(mktemp -d)"
  for bin in bash sh git mkdir ln mv rm date readlink basename dirname grep tail cat sed env; do
    p="$(command -v "${bin}" 2>/dev/null)" || continue
    ln -s "${p}" "${stub}/${bin}" 2>/dev/null || true
  done
  printf '%s\n' "${stub}"
}

test_preflight_requires_jq() {
  local home stub out rc
  home="$(fake_home)"
  stub="$(path_without_jq)"
  out="$(PATH="${stub}" HOME="${home}" bash "${REPO_DIR}/install.sh" 2>&1)"
  rc=$?
  assert_eq "${rc}" "1" "install.sh should exit 1 when jq is missing"
  contains "${out}" "jq" "error message should name jq"
  no "[ -e '${home}/.claude/rules/kotlin-spring.md' ]" "nothing should be created when preflight fails"
  no "[ -e '${home}/.claude/settings.json' ]" "settings.json should not be created when preflight fails"
  rm -rf "${home}" "${stub}"
}

test_hook_warns_on_pull_failure() {
  local home cmd
  home="$(fake_home)"
  run_install "${home}"
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "${home}/.claude/settings.json")"
  contains "${cmd}" "update failed" "hook command should warn on failure"
  not_contains "${cmd}" "|| true" "hook command should not swallow failures with || true"
  rm -rf "${home}"
}

# Every existing installation carries the OLD command string. Matching on the
# exact string would append a second entry instead of replacing the first.
test_hook_replaces_older_entry() {
  local home count cmd
  home="$(fake_home)"
  jq -n --arg cmd "git -C \"${REPO_DIR}\" pull --ff-only --quiet || true" \
    '{hooks:{SessionStart:[{matcher:"startup|resume",hooks:[{type:"command",command:$cmd,timeout:5}]}]}}' \
    > "${home}/.claude/settings.json"
  run_install "${home}"
  count="$(jq '[.hooks.SessionStart[].hooks[]] | length' "${home}/.claude/settings.json")"
  assert_eq "${count}" "1" "an older hook entry should be replaced, not duplicated"
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "${home}/.claude/settings.json")"
  contains "${cmd}" "update failed" "the surviving hook should be the current one"
  rm -rf "${home}"
}

main() {
  test_preflight_requires_jq
  test_hook_warns_on_pull_failure
  test_hook_replaces_older_entry
  printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
  [ "${FAILED}" -eq 0 ]
}

main "$@"
