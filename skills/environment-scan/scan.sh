#!/usr/bin/env bash
set -uo pipefail

SCAN_VERSION=1

emit() {
  printf '%s\n' "$*"
}

section() {
  printf '\n## %s\n' "$1"
}

redact() {
  grep -viE 'token|secret|password|passwd|apikey|api_key|credential|BEGIN [A-Z ]*PRIVATE KEY' || true
}

first_line() {
  head -n 1 | tr -d '\r'
}

probe() {
  local name="$1"
  local path version
  if ! path="$(command -v "${name}" 2> /dev/null)"; then
    emit "${name}: absent"
    return 0
  fi
  version="$(timeout 3 "${name}" --version 2> /dev/null | first_line | redact)"
  if [ -z "${version}" ]; then
    emit "${name}: present (${path})"
  else
    emit "${name}: present — ${version}"
  fi
}

boolean() {
  local label="$1"
  shift
  if timeout 3 "$@" > /dev/null 2>&1; then
    emit "${label}: yes"
  else
    emit "${label}: no"
  fi
}

report_header() {
  emit "# environment scan"
  emit "SCAN_VERSION: ${SCAN_VERSION}"
  emit "scanned: $(date -u +%Y-%m-%d)"
  emit "uname: $(uname -sr)"
}

scan_shell() {
  section "shell"
  emit "SHELL: ${SHELL:-unknown}"
  emit "PAGER: ${PAGER:-unset}"
  emit "EDITOR: ${EDITOR:-unset}"
  local name
  for name in fish bash zsh nu tmux zellij screen starship; do
    probe "${name}"
  done
}

scan_package_managers() {
  section "package-managers"
  local name
  for name in pacman paru yay apt dnf zypper apk brew nix flatpak snap \
              cargo npm pnpm yarn bun pipx uv gem composer; do
    probe "${name}"
  done
}

scan_cli_replacements() {
  section "cli-replacements"
  local name
  for name in rg fd bat eza lsd delta difftastic fzf zoxide jq yq sd \
              hyperfine tokei dust duf procs btop htop; do
    probe "${name}"
  done
}

scan_toolchains() {
  section "toolchains"
  local name
  for name in java javac kotlin kotlinc gradle mvn python3 pip3 node deno \
              bun go rustc cargo ruby php dotnet; do
    probe "${name}"
  done
  emit "JAVA_HOME: ${JAVA_HOME:-unset}"
}

scan_containers() {
  section "containers-and-cloud"
  local name
  for name in docker podman nerdctl kubectl helm k9s kustomize minikube \
              kind terraform aws gcloud az; do
    probe "${name}"
  done
  boolean "docker-daemon-reachable" docker info
  boolean "kubectl-context-configured" kubectl config current-context
}

scan_vcs() {
  section "vcs-and-forge"
  probe git
  probe gh
  probe glab
  probe git-lfs
  boolean "gh-authenticated" gh auth status
  boolean "glab-authenticated" glab auth status
  local key
  for key in init.defaultBranch pull.rebase commit.gpgsign merge.conflictstyle \
             rerere.enabled core.editor; do
    emit "git-config ${key}: $(git config --global --get "${key}" 2> /dev/null | redact || true)"
  done
}

scan_claude() {
  section "claude-code"
  local skills_dir="${HOME}/.claude/skills"
  local plugins_dir="${HOME}/.claude/plugins"
  if [ -d "${skills_dir}" ]; then
    emit "skills: $(find "${skills_dir}" -maxdepth 1 -mindepth 1 -printf '%f ' 2> /dev/null)"
  else
    emit "skills: absent"
  fi
  if [ -d "${plugins_dir}" ]; then
    emit "plugins: $(find "${plugins_dir}" -maxdepth 1 -mindepth 1 -printf '%f ' 2> /dev/null)"
  else
    emit "plugins: absent"
  fi
  emit "settings.json: $([ -f "${HOME}/.claude/settings.json" ] && echo present || echo absent)"
  if [ -f "${HOME}/.claude/settings.json" ] && command -v jq > /dev/null 2>&1; then
    emit "hooks configured: $(jq -r '(.hooks // {}) | keys | join(",")' "${HOME}/.claude/settings.json" 2> /dev/null)"
  fi
}

main() {
  report_header
  scan_shell
  scan_package_managers
  scan_cli_replacements
  scan_toolchains
  scan_containers
  scan_vcs
  scan_claude
}

main "$@"
