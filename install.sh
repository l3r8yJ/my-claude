#!/usr/bin/env bash
# Links this repo's guidance into ~/.claude/rules/ and its skills into
# ~/.claude/skills/, then wires a SessionStart hook that pulls the latest
# version of this repo before each Claude Code session. Never overwrites a
# file it did not create.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"
RULES_DIR="${CLAUDE_DIR}/rules"
RULE_FILE="${RULES_DIR}/kotlin-spring.md"
SKILLS_DIR="${CLAUDE_DIR}/skills"
SETTINGS="${CLAUDE_DIR}/settings.json"
IMPORT_LINE="@${REPO_DIR}/CLAUDE.md"
PULL_CMD="git -C \"${REPO_DIR}\" pull --ff-only --quiet || echo \"my-claude: update failed (local commits or no network); guidance may be stale — check: git -C ${REPO_DIR} status\""

for tool in git jq; do
  if ! command -v "${tool}" > /dev/null 2>&1; then
    echo "error: ${tool} is required but was not found on PATH. Nothing was changed." >&2
    exit 1
  fi
done

trap 'rm -f "${tmp:-}"' EXIT

mkdir -p "${CLAUDE_DIR}" "${RULES_DIR}"

symlink_points_to() {
  [ -L "$1" ] && [ "$(readlink "$1")" = "$2" ]
}

append_import() {
  if [ -f "${CLAUDE_MD}" ] && grep -qxF "${IMPORT_LINE}" "${CLAUDE_MD}"; then
    echo "Import already present in ${CLAUDE_MD}"
    return 0
  fi
  if [ -s "${CLAUDE_MD}" ] && [ -n "$(tail -c 1 "${CLAUDE_MD}")" ]; then
    printf '\n' >> "${CLAUDE_MD}"
  fi
  printf '%s\n' "${IMPORT_LINE}" >> "${CLAUDE_MD}"
  echo "Added import to ${CLAUDE_MD}: ${IMPORT_LINE}"
}

attach_guidance() {
  if symlink_points_to "${RULE_FILE}" "${REPO_DIR}/CLAUDE.md"; then
    echo "Already linked: ${RULE_FILE} -> ${REPO_DIR}/CLAUDE.md"
    return 0
  fi
  if [ -e "${RULE_FILE}" ] || [ -L "${RULE_FILE}" ]; then
    echo "warning: ${RULE_FILE} exists and was not created by this repo — skipping. Remove it and re-run to link this guidance." >&2
    return 0
  fi
  if ln -s "${REPO_DIR}/CLAUDE.md" "${RULE_FILE}" 2> /dev/null; then
    echo "Symlinked ${RULE_FILE} -> ${REPO_DIR}/CLAUDE.md"
    return 0
  fi
  echo "Symlinks unavailable here — falling back to a CLAUDE.md import."
  append_import
}

if symlink_points_to "${CLAUDE_MD}" "${REPO_DIR}/CLAUDE.md"; then
  rm "${CLAUDE_MD}"
  echo "Removed legacy symlink ${CLAUDE_MD}; guidance now loads from ${RULE_FILE}"
fi

attach_guidance

mkdir -p "${SKILLS_DIR}"

for skill_src in "${REPO_DIR}"/skills/*/; do
  skill_name="$(basename "${skill_src}")"
  skill_dst="${SKILLS_DIR}/${skill_name}"
  skill_target="${REPO_DIR}/skills/${skill_name}"
  if symlink_points_to "${skill_dst}" "${skill_target}"; then
    echo "Already linked: ${skill_dst} -> ${skill_target}"
  elif [ -e "${skill_dst}" ] || [ -L "${skill_dst}" ]; then
    echo "warning: ${skill_dst} exists and was not created by this repo — skipping. Remove it and re-run to link this repo's version." >&2
  else
    ln -s "${skill_target}" "${skill_dst}"
    echo "Symlinked ${skill_dst} -> ${skill_target}"
  fi
done

if [ ! -e "${SETTINGS}" ]; then
  echo '{}' > "${SETTINGS}"
fi

session_start_type="$(jq -r '.hooks.SessionStart | type' "${SETTINGS}" 2> /dev/null)" || session_start_type=""
if [ "${session_start_type}" != "" ] && [ "${session_start_type}" != "array" ] && [ "${session_start_type}" != "null" ]; then
  echo "error: ${SETTINGS} has .hooks.SessionStart set to type \"${session_start_type}\", not an array — symlinks and skills above are already in place, but nothing in ${SETTINGS} was modified. Fix that key and re-run to wire the hook." >&2
  exit 1
fi

tmp="$(mktemp "${SETTINGS}.XXXXXX")"
if ! jq --arg repo "${REPO_DIR}" --arg cmd "${PULL_CMD}" '
  .hooks //= {} |
  .hooks.SessionStart //= [] |
  .hooks.SessionStart |= (
    map(.hooks |= map(select(((.command // "") | contains($repo + "\"")) | not)))
    | map(select((.hooks | length) > 0))
  ) |
  .hooks.SessionStart += [{
    "matcher": "startup|resume",
    "hooks": [{"type": "command", "command": $cmd, "timeout": 5}]
  }]
' "${SETTINGS}" > "${tmp}"; then
  echo "error: ${SETTINGS} is not valid JSON — symlinks and skills above are already in place, but the hook was not wired. Fix or remove ${SETTINGS} and re-run." >&2
  exit 1
fi
mv "${tmp}" "${SETTINGS}"
echo "Wired SessionStart pull hook in ${SETTINGS}"
