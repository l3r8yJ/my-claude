#!/usr/bin/env bash
# Undoes install.sh: unlinks this repo's guidance and skills from ~/.claude
# and drops the SessionStart pull hook. Only removes symlinks and lines that
# this repo created; anything else is left alone with a warning.
# Does not delete this clone — remove the directory yourself afterwards.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"
RULES_DIR="${CLAUDE_DIR}/rules"
RULE_FILE="${RULES_DIR}/kotlin-spring.md"
SKILLS_DIR="${CLAUDE_DIR}/skills"
SETTINGS="${CLAUDE_DIR}/settings.json"
IMPORT_LINE="@${REPO_DIR}/CLAUDE.md"

if ! command -v jq > /dev/null 2>&1; then
  echo "error: jq is required but was not found on PATH. Nothing was changed." >&2
  exit 1
fi

trap 'rm -f "${tmp:-}"' EXIT

symlink_points_to() {
  [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]
}

if symlink_points_to "${RULE_FILE}" "${REPO_DIR}/CLAUDE.md"; then
  rm "${RULE_FILE}"
  echo "Removed ${RULE_FILE}"
elif [ -e "${RULE_FILE}" ] || [ -L "${RULE_FILE}" ]; then
  echo "warning: ${RULE_FILE} was not created by this repo — leaving it." >&2
fi

if symlink_points_to "${CLAUDE_MD}" "${REPO_DIR}/CLAUDE.md"; then
  rm "${CLAUDE_MD}"
  echo "Removed legacy symlink ${CLAUDE_MD}"
fi

if [ ! -L "${CLAUDE_MD}" ] && [ -f "${CLAUDE_MD}" ] && grep -qxF "${IMPORT_LINE}" "${CLAUDE_MD}"; then
  tmp="$(mktemp "${CLAUDE_MD}.XXXXXX")"
  grep -vxF "${IMPORT_LINE}" "${CLAUDE_MD}" > "${tmp}" || [ "$?" -le 1 ]
  mv "${tmp}" "${CLAUDE_MD}"
  echo "Removed import line from ${CLAUDE_MD}"
fi

if [ -d "${SKILLS_DIR}" ]; then
  for skill_src in "${REPO_DIR}"/skills/*/; do
    skill_name="$(basename "${skill_src}")"
    skill_dst="${SKILLS_DIR}/${skill_name}"
    skill_target="${REPO_DIR}/skills/${skill_name}"
    if symlink_points_to "${skill_dst}" "${skill_target}"; then
      rm "${skill_dst}"
      echo "Removed ${skill_dst}"
    elif [ -e "${skill_dst}" ] || [ -L "${skill_dst}" ]; then
      echo "warning: ${skill_dst} was not created by this repo — leaving it." >&2
    fi
  done
fi

if [ -f "${SETTINGS}" ]; then
  tmp="$(mktemp "${SETTINGS}.XXXXXX")"
  jq --arg repo "${REPO_DIR}" '
    if (.hooks.SessionStart | type) == "array" then
      .hooks.SessionStart |= (
        map(.hooks |= map(select(((.command // "") | contains($repo + "\"")) | not)))
        | map(select((.hooks | length) > 0))
      )
    else . end
    | if (.hooks.SessionStart? // []) == [] then del(.hooks.SessionStart) else . end
    | if (.hooks? // {}) == {} then del(.hooks) else . end
  ' "${SETTINGS}" > "${tmp}"
  mv "${tmp}" "${SETTINGS}"
  echo "Dropped this repo's SessionStart hook from ${SETTINGS}"
fi

echo "Done. The clone at ${REPO_DIR} was not deleted — remove it yourself if you no longer want it."
