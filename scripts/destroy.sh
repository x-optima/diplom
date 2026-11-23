#!/usr/bin/env bash
#
# Удаление ресурсов дипломного проекта.
#
#   ./scripts/destroy.sh            весь проект: приложения, машины, аккаунты
#   ./scripts/destroy.sh --yes      то же без запроса подтверждения
#   ./scripts/destroy.sh k8s        приложение, ingress-nginx, мониторинг
#   ./scripts/destroy.sh infra      машины кластера, сеть, реестр образов
#   ./scripts/destroy.sh bootstrap  сервисные аккаунты и бакет состояния
#
# Без аргумента этапы идут в порядке, обратном развёртыванию: сначала объекты
# в кластере, затем инфраструктура, затем бакет с файлом состояния.
# Отдельные этапы нужны, когда ресурсов уже нет или удалять нужно частично.
# Полное удаление запрашивает подтверждение: команда необратима.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/terraform/infrastructure"
BOOTSTRAP_DIR="${ROOT_DIR}/terraform/bootstrap"
TFVARS_FILE="${ROOT_DIR}/terraform/terraform.tfvars"

BOOTSTRAP_VARS="cloud_id folder_id zone name_prefix state_bucket_name service_account_key_file"
INFRA_VARS="cloud_id folder_id zones network_cidr subnet_prefix_length vm_image_family vm_user ssh_public_key_path vm_platform_id vm_core_fraction master_cores master_memory master_disk_size worker_count worker_cores worker_memory worker_disk_size registry_name service_account_key_file"

APP_NAMESPACE="app"
MONITORING_NAMESPACE="monitoring"
INGRESS_NAMESPACE="ingress-nginx"
MONITORING_RELEASE="kube-prometheus-stack"
INGRESS_RELEASE="ingress-nginx"

# Подтверждение полного удаления: 1 отключает вопрос, значение задаёт --yes.
ASSUME_YES=0

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

# Провайдер Yandex Cloud требует ключ сервисного аккаунта или IAM-токен.
# Токен из окружения перекрывает ключ, поэтому при наличии ключа он снимается.
ensure_yc_auth() {
  if [[ -f "${TFVARS_FILE}" ]] && grep -qE '^[[:space:]]*service_account_key_file[[:space:]]*=[[:space:]]*"[^"]+"' "${TFVARS_FILE}"; then
    if [[ -n "${YC_TOKEN:-}" ]]; then
      unset YC_TOKEN
      log "Авторизация: ключ сервисного аккаунта, токен из окружения отключён"
    fi
    return 0
  fi

  if [[ -n "${YC_TOKEN:-}" ]]; then
    return 0
  fi

  command -v yc >/dev/null 2>&1 || die "нет команды yc: задайте YC_TOKEN или укажите service_account_key_file в файле terraform/terraform.tfvars"
  YC_TOKEN="$(yc iam create-token)" || die "не удалось получить IAM-токен, проверьте авторизацию yc"
  export YC_TOKEN
  log "Авторизация: IAM-токен из текущей настройки yc, действует 12 часов"
}

# Готовит временный файл с переменными одного этапа.
stage_vars_file() {
  local names="$1" name out
  out="$(mktemp)"
  for name in ${names}; do
    grep -E "^[[:space:]]*${name}[[:space:]]*=" "${TFVARS_FILE}" >> "${out}" || true
  done
  printf '%s' "${out}"
}

# Ресурсы в кластере удаляются до инфраструктуры: релизы Helm создают объекты
# внутри машин, и после удаления самих машин убрать их будет нечем.
# Отсутствие кластера или helm не считается ошибкой: этап просто пропускается.
destroy_k8s() {
  if ! command -v kubectl >/dev/null 2>&1 || ! command -v helm >/dev/null 2>&1; then
    log "kubectl или helm не найдены, этап пропущен"
    return 0
  fi

  if ! kubectl cluster-info >/dev/null 2>&1; then
    log "Кластер недоступен, этап пропущен"
    return 0
  fi

  if helm status "${MONITORING_RELEASE}" -n "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
    log "Удаление ${MONITORING_RELEASE}"
    helm uninstall "${MONITORING_RELEASE}" -n "${MONITORING_NAMESPACE}" --wait --timeout 10m \
      || log "Релиз ${MONITORING_RELEASE} удалён с замечаниями"
  else
    log "Релиз ${MONITORING_RELEASE} не найден"
  fi

  if helm status "${INGRESS_RELEASE}" -n "${INGRESS_NAMESPACE}" >/dev/null 2>&1; then
    log "Удаление ${INGRESS_RELEASE}"
    helm uninstall "${INGRESS_RELEASE}" -n "${INGRESS_NAMESPACE}" --wait --timeout 10m \
      || log "Релиз ${INGRESS_RELEASE} удалён с замечаниями"
  else
    log "Релиз ${INGRESS_RELEASE} не найден"
  fi

  kubectl delete namespace "${APP_NAMESPACE}" --ignore-not-found --timeout=120s \
    || log "Пространство имён ${APP_NAMESPACE} удалено с замечаниями"
}

# Реестр не удаляется, пока в нём есть образы: API отвечает
# "Registry ... is not empty, you must delete all images first".
# Образы удаляются до terraform destroy, иначе удаление обрывается на реестре,
# а сеть и машины к этому моменту уже могут быть снесены.
clear_registry_images() {
  command -v yc >/dev/null 2>&1 || return 0
  [[ -f "${TFVARS_FILE}" ]] || return 0

  local folder_id registry_name registry_id api token images image_id code
  folder_id="$(grep -E '^[[:space:]]*folder_id[[:space:]]*=' "${TFVARS_FILE}" | sed 's/.*"\([^"]*\)".*/\1/' || true)"
  registry_name="$(grep -E '^[[:space:]]*registry_name[[:space:]]*=' "${TFVARS_FILE}" | sed 's/.*"\([^"]*\)".*/\1/' || true)"
  [[ -n "${folder_id}" && -n "${registry_name}" ]] || return 0

  registry_id="$(yc container registry get --name "${registry_name}" --folder-id "${folder_id}" --format json 2>/dev/null \
    | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/' || true)"
  if [[ -z "${registry_id}" ]]; then
    log "Реестр ${registry_name} не найден, очистка образов не нужна"
    return 0
  fi

  command -v curl >/dev/null 2>&1 || return 0

  # Команда "yc container image delete" в установленной версии CLI завершается
  # сбоем, поэтому список и удаление выполняются запросами к API.
  token="$(yc iam create-token 2>/dev/null || true)"
  if [[ -z "${token}" ]]; then
    log "Не удалось получить токен, образы в реестре ${registry_name} не очищены"
    return 0
  fi

  api="https://container-registry.api.cloud.yandex.net/container-registry/v1"
  images="$(curl -s -H "Authorization: Bearer ${token}" "${api}/images?registryId=${registry_id}" \
    | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' | sed 's/.*"\([^"]*\)"$/\1/' | sort -u || true)"
  if [[ -z "${images}" ]]; then
    log "Реестр ${registry_name} пуст"
    return 0
  fi

  for image_id in ${images}; do
    log "Удаление образа ${image_id} из реестра ${registry_name}"
    code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer ${token}" "${api}/images/${image_id}" || true)"
    case "${code}" in
      200 | 204) log "Образ ${image_id} удалён" ;;
      *) log "Образ ${image_id} удалить не удалось, ответ ${code}" ;;
    esac
  done
}

destroy_infra() {
  require_tool terraform
  [[ -f "${INFRA_DIR}/backend.hcl" ]] \
    || die "не найден terraform/infrastructure/backend.hcl: состояние инфраструктуры хранится в бакете, без файла доступа удаление невозможно"

  clear_registry_images

  local vars
  vars="$(stage_vars_file "${INFRA_VARS}")"

  log "Удаление машин кластера, сети и реестра образов"
  terraform -chdir="${INFRA_DIR}" init -input=false -backend-config=backend.hcl
  terraform -chdir="${INFRA_DIR}" destroy -auto-approve -var-file="${vars}"
  rm -f "${vars}"
}

destroy_bootstrap() {
  require_tool terraform

  local vars
  vars="$(stage_vars_file "${BOOTSTRAP_VARS}")"

  log "Удаление сервисных аккаунтов и бакета состояния"
  terraform -chdir="${BOOTSTRAP_DIR}" init -input=false
  terraform -chdir="${BOOTSTRAP_DIR}" destroy -auto-approve -var-file="${vars}"
  rm -f "${vars}"

  # Ключ доступа принадлежал удалённому сервисному аккаунту и больше не нужен.
  if [[ -f "${INFRA_DIR}/backend.hcl" ]]; then
    rm -f "${INFRA_DIR}/backend.hcl"
    log "Файл terraform/infrastructure/backend.hcl удалён"
  fi

  # В состоянии подготовительного этапа лежит закрытая часть ключа сервисного
  # аккаунта, в резервной копии — тоже. Аккаунт удалён, файлы не нужны.
  local state_file
  for state_file in "${BOOTSTRAP_DIR}/terraform.tfstate" "${BOOTSTRAP_DIR}/terraform.tfstate.backup"; do
    [[ -f "${state_file}" ]] && rm -f "${state_file}"
  done
  log "Локальное состояние подготовительного этапа удалено"

  # Пароль администратора Grafana создаётся заново при следующем развёртывании.
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    rm -f "${ROOT_DIR}/.env"
    log "Файл .env с паролем Grafana удалён"
  fi
}

# Перечисляет, что осталось в каталоге после удаления. Машины, диски и
# балансировщики тарифицируются отдельно, поэтому проверяются явно.
report_leftovers() {
  command -v yc >/dev/null 2>&1 || return 0
  [[ -f "${TFVARS_FILE}" ]] || return 0

  local folder_id machines disks networks registries balancers buckets
  folder_id="$(grep -E '^[[:space:]]*folder_id[[:space:]]*=' "${TFVARS_FILE}" | sed 's/.*"\([^"]*\)".*/\1/')"
  [[ -n "${folder_id}" ]] || return 0

  log "Проверка остатков в каталоге ${folder_id}"

  machines="$(yc compute instance list --folder-id "${folder_id}" --format json 2>/dev/null | grep -c '"id"' || true)"
  disks="$(yc compute disk list --folder-id "${folder_id}" --format json 2>/dev/null | grep -c '"id"' || true)"
  networks="$(yc vpc network list --folder-id "${folder_id}" --format json 2>/dev/null | grep -c '"id"' || true)"
  registries="$(yc container registry list --folder-id "${folder_id}" --format json 2>/dev/null | grep -c '"id"' || true)"
  balancers="$(yc load-balancer network-load-balancer list --folder-id "${folder_id}" --format json 2>/dev/null | grep -c '"id"' || true)"
  buckets="$(yc storage bucket list --folder-id "${folder_id}" --format json 2>/dev/null | grep -c '"name"' || true)"

  printf '%s\n' \
    "  виртуальные машины:       ${machines:-0}" \
    "  диски:                    ${disks:-0}" \
    "  сети:                     ${networks:-0}" \
    "  реестры образов:          ${registries:-0}" \
    "  сетевые балансировщики:   ${balancers:-0}" \
    "  бакеты:                   ${buckets:-0}"
}

# Полное удаление затрагивает всё, что создано проектом, и отменить его нельзя.
# Подтверждение не запрашивается при флаге --yes и в неинтерактивном запуске,
# где ответить на вопрос некому.
confirm_full_destruction() {
  if ((ASSUME_YES == 1)); then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "полное удаление без подтверждения требует флага --yes"
  fi

  printf 'Будут удалены машины кластера, сеть, реестр образов,\n'
  printf 'сервисные аккаунты и бакет с файлом состояния.\n'
  printf 'Введите delete для продолжения: '

  local answer
  read -r answer
  [[ "${answer}" == "delete" ]] || die "удаление отменено"
}

main() {
  local stage="all" arg

  for arg in "$@"; do
    case "${arg}" in
      --yes | -y) ASSUME_YES=1 ;;
      k8s | infra | bootstrap | all) stage="${arg}" ;;
      *)
        sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
    esac
  done

  if [[ "${stage}" != "k8s" ]]; then
    [[ -f "${TFVARS_FILE}" ]] \
      || die "нет файла terraform/terraform.tfvars: скопируйте его из terraform/terraform.tfvars.example"
    ensure_yc_auth
  fi

  if [[ "${stage}" == "all" ]]; then
    confirm_full_destruction
  fi

  case "${stage}" in
    k8s) destroy_k8s ;;
    infra) destroy_infra ;;
    bootstrap) destroy_bootstrap ;;
    all)
      log "Удаление проекта целиком"
      destroy_k8s
      destroy_infra
      destroy_bootstrap
      report_leftovers
      log "Удаление завершено"
      ;;
  esac
}

main "$@"
