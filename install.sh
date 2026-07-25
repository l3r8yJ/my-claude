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

mkdir -p "${CLAUDE_DIR}" "${RULES_DIR}"

if [ -e "${CLAUDE_MD}" ] || [ -L "${CLAUDE_MD}" ]; then
  if [ "$(readlink "${CLAUDE_MD}" 2>/dev/null || true)" = "${REPO_DIR}/CLAUDE.md" ]; then
    echo "Symlink already in place: ${CLAUDE_MD} -> ${REPO_DIR}/CLAUDE.md"
  else
    BACKUP="${CLAUDE_MD}.bak.$(date +%Y%m%d%H%M%S)"
    mv "${CLAUDE_MD}" "${BACKUP}"
    echo "Backed up existing ${CLAUDE_MD} -> ${BACKUP}"
    ln -sf "${REPO_DIR}/CLAUDE.md" "${CLAUDE_MD}"
    echo "Symlinked ${CLAUDE_MD} -> ${REPO_DIR}/CLAUDE.md"
  fi
else
  ln -sf "${REPO_DIR}/CLAUDE.md" "${CLAUDE_MD}"
  echo "Symlinked ${CLAUDE_MD} -> ${REPO_DIR}/CLAUDE.md"
fi

mkdir -p "${SKILLS_DIR}"

for skill_src in "${REPO_DIR}"/skills/*/; do
  skill_name="$(basename "${skill_src}")"
  skill_dst="${SKILLS_DIR}/${skill_name}"
  if [ -e "${skill_dst}" ] || [ -L "${skill_dst}" ]; then
    if [ "$(readlink "${skill_dst}" 2>/dev/null || true)" = "${REPO_DIR}/skills/${skill_name}" ]; then
      echo "Symlink already in place: ${skill_dst} -> ${REPO_DIR}/skills/${skill_name}"
    else
      BACKUP="${skill_dst}.bak.$(date +%Y%m%d%H%M%S)"
      mv "${skill_dst}" "${BACKUP}"
      echo "Backed up existing ${skill_dst} -> ${BACKUP}"
      ln -sf "${REPO_DIR}/skills/${skill_name}" "${skill_dst}"
      echo "Symlinked ${skill_dst} -> ${REPO_DIR}/skills/${skill_name}"
    fi
  else
    ln -sf "${REPO_DIR}/skills/${skill_name}" "${skill_dst}"
    echo "Symlinked ${skill_dst} -> ${REPO_DIR}/skills/${skill_name}"
  fi
done

if [ ! -e "${SETTINGS}" ]; then
  echo '{}' > "${SETTINGS}"
fi

tmp="$(mktemp)"
jq --arg repo "${REPO_DIR}" --arg cmd "${PULL_CMD}" '
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
' "${SETTINGS}" > "${tmp}"
mv "${tmp}" "${SETTINGS}"
echo "Wired SessionStart pull hook in ${SETTINGS}"
