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

test_hook_preserves_sibling_repo_entry() {
  local home cmds
  home="$(fake_home)"
  jq -n --arg cmd "git -C \"${REPO_DIR}-fork\" pull --ff-only --quiet || true" \
    '{hooks:{SessionStart:[{matcher:"startup|resume",hooks:[{type:"command",command:$cmd,timeout:5}]}]}}' \
    > "${home}/.claude/settings.json"
  run_install "${home}"
  cmds="$(jq -r '[.hooks.SessionStart[].hooks[].command] | join("|")' "${home}/.claude/settings.json")"
  contains "${cmds}" "${REPO_DIR}-fork" "a sibling repo's hook must survive install"
  contains "${cmds}" "update failed" "this repo's hook should still be added"
  rm -rf "${home}"
}

test_fresh_install_links_rule_file() {
  local home
  home="$(fake_home)"
  run_install "${home}"
  ok "[ -L '${home}/.claude/rules/kotlin-spring.md' ]" "rule file should be a symlink"
  assert_eq "$(readlink "${home}/.claude/rules/kotlin-spring.md")" \
    "${REPO_DIR}/CLAUDE.md" "rule symlink should point at the repo CLAUDE.md"
  no "[ -e '${home}/.claude/CLAUDE.md' ]" "install must not create ~/.claude/CLAUDE.md"
  rm -rf "${home}"
}

test_existing_user_claude_md_is_untouched() {
  local home before after
  home="$(fake_home)"
  printf '# my own rules\n- do the thing\n' > "${home}/.claude/CLAUDE.md"
  before="$(cat "${home}/.claude/CLAUDE.md")"
  run_install "${home}"
  after="$(cat "${home}/.claude/CLAUDE.md")"
  assert_eq "${after}" "${before}" "user's own CLAUDE.md must be byte-identical"
  no "ls ${home}/.claude/CLAUDE.md.bak.* >/dev/null 2>&1" "no .bak file should be created"
  rm -rf "${home}"
}

test_legacy_symlink_is_migrated() {
  local home
  home="$(fake_home)"
  ln -s "${REPO_DIR}/CLAUDE.md" "${home}/.claude/CLAUDE.md"
  run_install "${home}"
  no "[ -e '${home}/.claude/CLAUDE.md' ] || [ -L '${home}/.claude/CLAUDE.md' ]" \
    "legacy repo symlink at ~/.claude/CLAUDE.md should be removed"
  ok "[ -L '${home}/.claude/rules/kotlin-spring.md' ]" "guidance should now load via rules/"
  rm -rf "${home}"
}

test_falls_back_to_import_when_symlink_unavailable() {
  local home count
  home="$(fake_home)"
  mkdir -p "${home}/.claude/rules"
  chmod 500 "${home}/.claude/rules"
  run_install "${home}"
  ok "[ -f '${home}/.claude/CLAUDE.md' ]" "fallback should create ~/.claude/CLAUDE.md"
  ok "grep -qxF '@${REPO_DIR}/CLAUDE.md' '${home}/.claude/CLAUDE.md'" \
    "fallback should append the import line"
  run_install "${home}"
  count="$(grep -cxF "@${REPO_DIR}/CLAUDE.md" "${home}/.claude/CLAUDE.md")"
  assert_eq "${count}" "1" "import line must not be duplicated on re-run"
  chmod 700 "${home}/.claude/rules"
  rm -rf "${home}"
}

test_skills_are_linked() {
  local home name
  home="$(fake_home)"
  run_install "${home}"
  for name in kotlin-test-writing-rules mapstruct-converter-conventions \
              jooq-repository-pattern nextbi-analytics-contracts; do
    ok "[ -L '${home}/.claude/skills/${name}' ]" "${name} should be symlinked"
    assert_eq "$(readlink "${home}/.claude/skills/${name}")" \
      "${REPO_DIR}/skills/${name}" "${name} should point into the repo"
  done
  rm -rf "${home}"
}

test_foreign_skill_is_preserved() {
  local home marker
  home="$(fake_home)"
  mkdir -p "${home}/.claude/skills/kotlin-test-writing-rules"
  printf 'mine\n' > "${home}/.claude/skills/kotlin-test-writing-rules/SKILL.md"
  run_install "${home}"
  ok "[ -d '${home}/.claude/skills/kotlin-test-writing-rules' ]" \
    "user's own skill directory must survive"
  no "[ -L '${home}/.claude/skills/kotlin-test-writing-rules' ]" \
    "user's own skill must not be replaced by a symlink"
  marker="$(cat "${home}/.claude/skills/kotlin-test-writing-rules/SKILL.md")"
  assert_eq "${marker}" "mine" "user's skill content must be unchanged"
  no "ls -d ${home}/.claude/skills/*.bak.* >/dev/null 2>&1" "no .bak directory should be created"
  ok "[ -L '${home}/.claude/skills/jooq-repository-pattern' ]" \
    "other skills should still be linked after a skip"
  rm -rf "${home}"
}

test_remove_undoes_install() {
  local home before after
  home="$(fake_home)"
  printf '{"theme":"auto"}\n' > "${home}/.claude/settings.json"
  before="$(jq -S . "${home}/.claude/settings.json")"
  run_install "${home}"
  run_remove "${home}"
  no "[ -e '${home}/.claude/rules/kotlin-spring.md' ] || [ -L '${home}/.claude/rules/kotlin-spring.md' ]" \
    "rule symlink should be gone"
  no "ls ${home}/.claude/skills/* >/dev/null 2>&1" "skill symlinks should be gone"
  after="$(jq -S . "${home}/.claude/settings.json")"
  assert_eq "${after}" "${before}" "settings.json should be restored to its prior content"
  rm -rf "${home}"
}

test_remove_is_idempotent_and_safe_on_clean_machine() {
  local home before after
  home="$(fake_home)"
  printf '{"theme":"auto"}\n' > "${home}/.claude/settings.json"
  before="$(jq -S . "${home}/.claude/settings.json")"
  ok "run_remove '${home}'" "remove.sh must exit 0 on a never-installed machine"
  after="$(jq -S . "${home}/.claude/settings.json")"
  assert_eq "${after}" "${before}" "remove on a never-installed machine must change nothing"
  rm -rf "${home}"
}

test_remove_after_install_is_idempotent() {
  local home first_state second_state
  home="$(fake_home)"
  run_install "${home}"
  ok "run_remove '${home}'" "remove.sh must exit 0 right after an install"
  first_state="$(find "${home}/.claude" | sort)
$(jq -S . "${home}/.claude/settings.json" 2>/dev/null)"
  ok "run_remove '${home}'" "remove.sh must exit 0 again when there is nothing left to remove"
  second_state="$(find "${home}/.claude" | sort)
$(jq -S . "${home}/.claude/settings.json" 2>/dev/null)"
  assert_eq "${second_state}" "${first_state}" "a second remove must not change state left by the first"
  rm -rf "${home}"
}

test_remove_preserves_foreign_content() {
  local home own_skill own_md other_hook
  home="$(fake_home)"
  mkdir -p "${home}/.claude/skills/my-own-skill"
  printf 'mine\n' > "${home}/.claude/skills/my-own-skill/SKILL.md"
  printf '# my rules\n' > "${home}/.claude/CLAUDE.md"
  jq -n '{hooks:{SessionStart:[{matcher:"startup",hooks:[{type:"command",command:"echo unrelated"}]}]}}' \
    > "${home}/.claude/settings.json"
  run_install "${home}"
  run_remove "${home}"
  own_skill="$(cat "${home}/.claude/skills/my-own-skill/SKILL.md")"
  assert_eq "${own_skill}" "mine" "unrelated skill must survive remove"
  own_md="$(cat "${home}/.claude/CLAUDE.md")"
  assert_eq "${own_md}" "# my rules" "user's CLAUDE.md must survive remove unchanged"
  other_hook="$(jq -r '[.hooks.SessionStart[].hooks[].command] | join(",")' "${home}/.claude/settings.json")"
  assert_eq "${other_hook}" "echo unrelated" "unrelated SessionStart hook must survive"
  rm -rf "${home}"
}

test_remove_strips_import_line_preserving_user_content() {
  local home expected actual
  home="$(fake_home)"
  printf '# my own rules\n@%s/CLAUDE.md\nmore of my stuff\n' "${REPO_DIR}" > "${home}/.claude/CLAUDE.md"
  expected="$(printf '# my own rules\nmore of my stuff\n')"
  ok "run_remove '${home}'" "remove.sh must exit 0 when stripping the import line from a real file"
  actual="$(cat "${home}/.claude/CLAUDE.md")"
  assert_eq "${actual}" "${expected}" "user content around the import line must be byte-identical after the strip"
  rm -rf "${home}"
}

test_remove_completes_when_claude_md_has_only_import_line() {
  local home
  home="$(fake_home)"
  mkdir -p "${home}/.claude/rules"
  chmod 500 "${home}/.claude/rules"
  run_install "${home}"
  chmod 700 "${home}/.claude/rules"
  ok "[ -f '${home}/.claude/CLAUDE.md' ]" \
    "setup: fallback install should create CLAUDE.md with only the import line"
  ok "run_remove '${home}'" "remove.sh must exit 0 when CLAUDE.md contains only the import line"
  no "[ -f '${home}/.claude/CLAUDE.md' ] && grep -qxF '@${REPO_DIR}/CLAUDE.md' '${home}/.claude/CLAUDE.md'" \
    "import line must be gone"
  no "ls ${home}/.claude/skills/* >/dev/null 2>&1" \
    "skill symlinks must also be removed — a mid-script death on the import-line strip must not abort the rest of the uninstall"
  rm -rf "${home}"
}

test_remove_preserves_foreign_claude_md_symlink() {
  local home dotfiles target expected_content
  home="$(fake_home)"
  dotfiles="$(mktemp -d)"
  target="${dotfiles}/shared-CLAUDE.md"
  expected_content="$(printf '# shared dotfiles rules\n@%s/CLAUDE.md\n' "${REPO_DIR}")"
  printf '%s\n' "${expected_content}" > "${target}"
  ln -s "${target}" "${home}/.claude/CLAUDE.md"
  ok "run_remove '${home}'" "remove.sh must exit 0 with a foreign CLAUDE.md symlink present"
  ok "[ -L '${home}/.claude/CLAUDE.md' ]" \
    "user's own CLAUDE.md symlink must still be a symlink, not replaced by a regular file"
  assert_eq "$(readlink "${home}/.claude/CLAUDE.md")" "${target}" \
    "user's own CLAUDE.md symlink must still point at its original target"
  assert_eq "$(cat "${target}")" "${expected_content}" \
    "the symlink's target file content must be untouched by remove.sh"
  rm -rf "${home}" "${dotfiles}"
}

main() {
  test_preflight_requires_jq
  test_hook_warns_on_pull_failure
  test_hook_replaces_older_entry
  test_hook_preserves_sibling_repo_entry
  test_fresh_install_links_rule_file
  test_existing_user_claude_md_is_untouched
  test_legacy_symlink_is_migrated
  test_falls_back_to_import_when_symlink_unavailable
  test_skills_are_linked
  test_foreign_skill_is_preserved
  test_remove_undoes_install
  test_remove_is_idempotent_and_safe_on_clean_machine
  test_remove_after_install_is_idempotent
  test_remove_preserves_foreign_content
  test_remove_strips_import_line_preserving_user_content
  test_remove_completes_when_claude_md_has_only_import_line
  test_remove_preserves_foreign_claude_md_symlink
  printf '\n%d passed, %d failed\n' "${PASSED}" "${FAILED}"
  [ "${FAILED}" -eq 0 ]
}

main "$@"
