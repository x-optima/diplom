#!/usr/bin/env bash
#
# Удаление ресурсов дипломного проекта.
#
#   ./scripts/destroy.sh infra      кластер, сеть, реестр образов
#   ./scripts/destroy.sh bootstrap  сервисные аккаунты и бакет состояния
#
# Бакет удаляется последним: в нём хранится файл состояния инфраструктуры.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/terraform/infrastructure"
BOOTSTRAP_DIR="${ROOT_DIR}/terraform/bootstrap"

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "не найдена команда $1"
}

destroy_infra() {
  require_tool terraform
  [[ -f "${INFRA_DIR}/backend.hcl" ]] || die "не найден terraform/infrastructure/backend.hcl"

  log "Удаление кластера, сети и реестра образов"
  terraform -chdir="${INFRA_DIR}" init -input=false -backend-config=backend.hcl
  terraform -chdir="${INFRA_DIR}" destroy -input=false
}

destroy_bootstrap() {
  require_tool terraform

  log "Удаление сервисных аккаунтов и бакета состояния"
  terraform -chdir="${BOOTSTRAP_DIR}" init -input=false
  terraform -chdir="${BOOTSTRAP_DIR}" destroy -input=false
}

main() {
  case "${1:-}" in
    infra) destroy_infra ;;
    bootstrap) destroy_bootstrap ;;
    *)
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 1
      ;;
  esac
}

main "$@"
