#!/usr/bin/env bash
#
# Развёртывание дипломного проекта.
#
#   ./scripts/deploy.sh              весь проект от начала до конца
#   ./scripts/deploy.sh bootstrap    только сервисные аккаунты и бакет состояния
#   ./scripts/deploy.sh infra        только сеть, три машины кластера, реестр образов
#   ./scripts/deploy.sh cluster      установка Kubernetes на машины через Ansible
#   ./scripts/deploy.sh kubeconfig   файл доступа к кластеру в ~/.kube/config
#   ./scripts/deploy.sh ingress      контроллер ingress-nginx
#   ./scripts/deploy.sh monitoring   Prometheus, Grafana, Alertmanager, node-exporter
#   ./scripts/deploy.sh app          сборка образа и развёртывание приложения
#   ./scripts/deploy.sh status       состояние подов, сервисов и ingress
#
# Без аргумента выполняются все этапы подряд. Отдельные этапы нужны для отладки:
# повторный запуск пропускает то, что уже создано.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/terraform/infrastructure"
BOOTSTRAP_DIR="${ROOT_DIR}/terraform/bootstrap"
K8S_DIR="${ROOT_DIR}/k8s"
TFVARS_FILE="${ROOT_DIR}/terraform/terraform.tfvars"

# Переменные каждого этапа. Единый файл содержит оба набора, поэтому этапу
# передаётся только то, что объявлено в его конфигурации.
BOOTSTRAP_VARS="cloud_id folder_id zone name_prefix state_bucket_name service_account_key_file"
INFRA_VARS="cloud_id folder_id zones network_cidr subnet_prefix_length vm_image_family vm_user ssh_public_key_path vm_platform_id vm_core_fraction master_cores master_memory master_disk_size worker_count worker_cores worker_memory worker_disk_size registry_name service_account_key_file"

APP_NAMESPACE="app"
MONITORING_NAMESPACE="monitoring"
MONITORING_RELEASE="kube-prometheus-stack"
INGRESS_RELEASE="ingress-nginx"
APP_NAME="diplom-app"

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

load_env() {
  local env_file="${ROOT_DIR}/.env"

  # При первом запуске файл создаётся сам: пароль администратора Grafana
  # нужен этапу monitoring, а хранить его в репозитории нельзя.
  if [[ ! -f "${env_file}" ]]; then
    local password
    password="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
    umask 077
    printf 'GRAFANA_PASSWORD=%s\nAPP_VERSION=latest\n' "${password}" > "${env_file}"
    chmod 600 "${env_file}"
    log "Создан файл .env с паролем администратора Grafana"
  fi

  set -a
  # shellcheck disable=SC1091
  source "${env_file}"
  set +a

  GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"
  APP_VERSION="${APP_VERSION:-latest}"
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

# Файл доступа к бакету состояния создаётся один раз, при первом запуске этапа
# infra. Закрытая часть статического ключа показывается облаком только в момент
# создания, поэтому она сразу пишется в файл с правами 600 и не выводится
# в терминал. Повторно ключ не создаётся: файл уже существует.
ensure_backend_hcl() {
  local file="${INFRA_DIR}/backend.hcl"
  if [[ -f "${file}" ]]; then
    return 0
  fi

  require_tool yc
  require_tool python3

  local sa_id bucket key_file
  sa_id="$(terraform -chdir="${BOOTSTRAP_DIR}" output -raw terraform_service_account_id 2>/dev/null)" \
    || die "не удалось прочитать идентификатор сервисного аккаунта: выполните ./scripts/deploy.sh bootstrap"
  bucket="$(terraform -chdir="${BOOTSTRAP_DIR}" output -raw state_bucket 2>/dev/null)" \
    || die "не удалось прочитать имя бакета состояния: выполните ./scripts/deploy.sh bootstrap"

  local template="${INFRA_DIR}/backend.hcl.example"
  if ! grep -q 'YCAJXXXXXXXXXXXXXXXXXXXX' "${template}" \
      || ! grep -q 'YCPXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' "${template}"; then
    die "в шаблоне terraform/infrastructure/backend.hcl.example изменились заполнители ключа доступа"
  fi

  log "Файл backend.hcl отсутствует, создаю ключ доступа к бакету ${bucket}"

  key_file="$(mktemp)"
  chmod 600 "${key_file}"

  if ! yc iam access-key create \
      --service-account-id "${sa_id}" \
      --description "Terraform backend" \
      --format json > "${key_file}"; then
    rm -f "${key_file}"
    die "не удалось создать ключ доступа: проверьте роль iam.serviceAccounts.admin у учётной записи yc"
  fi

  # Структура ответа CLI отличается между версиями: закрытая часть ключа
  # встречается и внутри объекта access_key, и рядом с ним. Поля ищутся
  # рекурсивно, чтобы разбор не зависел от вложенности.
  local status=0
  python3 - "${key_file}" "${bucket}" "${template}" "${file}" <<'PY' || status=$?
import json
import sys

key_file, bucket, template, destination = sys.argv[1:5]


def find_field(node, name):
    if isinstance(node, dict):
        value = node.get(name)
        if isinstance(value, str) and value:
            return value
        for nested in node.values():
            found = find_field(nested, name)
            if found:
                return found
    elif isinstance(node, list):
        for item in node:
            found = find_field(item, name)
            if found:
                return found
    return None


with open(key_file, encoding="utf-8") as source:
    payload = json.load(source)

key_id = find_field(payload, "key_id")
secret = find_field(payload, "secret") or find_field(payload, "secret_key")

if not key_id or not secret:
    sys.exit(2)

with open(template, encoding="utf-8") as source:
    text = source.read()

text = text.replace("diplom-tfstate-0000000000000", bucket)
text = text.replace("YCAJXXXXXXXXXXXXXXXXXXXX", key_id)
text = text.replace("YCPXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX", secret)

if "XXXX" in text:
    sys.exit(3)

with open(destination, "w", encoding="utf-8") as target:
    target.write(text)
PY

  if (( status == 2 )); then
    rm -f "${key_file}" "${file}"
    die "облако не вернуло закрытую часть ключа: лишний ключ удалите командой yc iam access-key list --service-account-id ${sa_id}, затем повторите этап"
  fi
  if (( status == 3 )); then
    rm -f "${key_file}" "${file}"
    die "в шаблоне terraform/infrastructure/backend.hcl.example изменились заполнители, подстановка не удалась"
  fi
  if (( status != 0 )); then
    rm -f "${key_file}" "${file}"
    die "не удалось заполнить terraform/infrastructure/backend.hcl, код ${status}"
  fi

  rm -f "${key_file}"
  chmod 600 "${file}"
  log "Файл terraform/infrastructure/backend.hcl создан"
}

# Провайдер Yandex Cloud требует либо ключ сервисного аккаунта, либо IAM-токен.
# Токен из окружения перекрывает ключ, поэтому при наличии ключа он снимается:
# иначе применяется аккаунт, под которым получен токен, и роли могут не совпасть.
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

bootstrap() {
  require_tool terraform
  [[ -f "${TFVARS_FILE}" ]] || die "нет файла terraform/terraform.tfvars: скопируйте его из terraform/terraform.tfvars.example"

  local vars
  vars="$(stage_vars_file "${BOOTSTRAP_VARS}")"

  log "Подготовительный этап: сервисные аккаунты и бакет состояния"
  terraform -chdir="${BOOTSTRAP_DIR}" init -input=false
  terraform -chdir="${BOOTSTRAP_DIR}" apply -auto-approve -var-file="${vars}"
  rm -f "${vars}"
}

infra() {
  require_tool terraform
  [[ -f "${TFVARS_FILE}" ]] || die "нет файла terraform/terraform.tfvars: скопируйте его из terraform/terraform.tfvars.example"
  ensure_backend_hcl

  local vars
  vars="$(stage_vars_file "${INFRA_VARS}")"

  log "Создание сети, машин кластера и реестра образов"
  terraform -chdir="${INFRA_DIR}" init -input=false -backend-config=backend.hcl
  terraform -chdir="${INFRA_DIR}" apply -auto-approve -var-file="${vars}"
  rm -f "${vars}"
}

kubeconfig() {
  require_tool scp
  require_tool kubectl

  local master user key
  master="$(master_ip)"
  user="${VM_USER:-k8s}"
  key="${SSH_KEY_PATH:-${HOME}/.ssh/yandex}"

  log "Копирование файла доступа с управляющей машины ${master}"
  mkdir -p "${HOME}/.kube"

  scp -i "${key}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${user}@${master}:/home/${user}/.kube/config" "${HOME}/.kube/config" \
    || die "не удалось скопировать файл доступа: проверьте ключ ${key}"

  # В конфигурации указан внутренний адрес API-сервера, снаружи он недоступен.
  sed -i -E "s#server: https://[0-9.]+:6443#server: https://${master}:6443#" "${HOME}/.kube/config"

  kubectl get nodes -o wide
}

cluster() {
  require_tool ansible-playbook

  local inventory="${ROOT_DIR}/ansible/inventory.ini"
  [[ -f "${inventory}" ]] \
    || die "нет файла ansible/inventory.ini: выполните ./scripts/deploy.sh infra"

  log "Установка Kubernetes на подготовленные машины"
  ( cd "${ROOT_DIR}/ansible" && ansible-playbook playbook-k8s.yml )
}

ingress() {
  require_tool helm
  log "Установка контроллера ingress-nginx"
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
  helm repo update ingress-nginx >/dev/null
  helm upgrade --install "${INGRESS_RELEASE}" ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --values "${K8S_DIR}/ingress-nginx/values.yaml" \
    --wait \
    --timeout 10m
}

# Внешний адрес входа: контроллер ingress работает на рабочих узлах и
# занимает порты 80 и 443, поэтому отдельный балансировщик не нужен.
master_ip() {
  local ip
  ip="$(terraform -chdir="${INFRA_DIR}" output -raw master_external_ip 2>/dev/null || true)"
  [[ -n "${ip}" ]] || die "не удалось прочитать адрес управляющей машины: выполните ./scripts/deploy.sh infra"
  printf '%s' "${ip}"
}

# Адрес для обращения к приложению и Grafana: первый внешний адрес рабочего
# узла, на котором размещён контроллер.
ingress_ip() {
  local ip
  ip="$(terraform -chdir="${INFRA_DIR}" output -json worker_external_ips 2>/dev/null \
    | tr -d '[]" ' | cut -d, -f1 || true)"
  [[ -n "${ip}" ]] && printf '%s' "${ip}" && return 0
  master_ip
}

monitoring() {
  require_tool helm
  [[ -n "${GRAFANA_PASSWORD}" ]] || die "задайте GRAFANA_PASSWORD в файле .env"

  local ip grafana_host
  ip="$(ingress_ip)"
  grafana_host="grafana.${ip}.nip.io"

  log "Установка kube-prometheus-stack в пространство имён ${MONITORING_NAMESPACE}"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm repo update prometheus-community >/dev/null

  kubectl create namespace "${MONITORING_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

  kubectl -n "${MONITORING_NAMESPACE}" create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="${GRAFANA_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  GRAFANA_HOST="${grafana_host}" \
    envsubst '${GRAFANA_HOST}' < "${K8S_DIR}/monitoring/kube-prometheus-values.yaml" \
    | helm upgrade --install "${MONITORING_RELEASE}" prometheus-community/kube-prometheus-stack \
        --namespace "${MONITORING_NAMESPACE}" \
        --values - \
        --wait \
        --timeout 20m

  kubectl -n "${MONITORING_NAMESPACE}" get pods
}

# Отдельный сборщик buildx: он держит слои в своём хранилище и не обращается к
# кешу демона, где остаются сведения о реестрах прошлых сборок. Иначе отправка
# в новый реестр пытается переиспользовать слои удалённого и завершается
# ошибкой Registry not found.
BUILDX_BUILDER="diplom-builder"

build_and_push() {
  require_tool docker
  require_tool yc

  local registry_id image

  docker buildx version >/dev/null 2>&1 \
    || die "не найден плагин buildx (пакет docker-buildx-plugin)"

  registry_id="$(terraform -chdir="${INFRA_DIR}" output -raw registry_id)"
  image="cr.yandex/${registry_id}/${APP_NAME}:${APP_VERSION}"

  log "Сборка образа ${image}"
  yc container registry configure-docker >/dev/null

  if ! docker buildx inspect "${BUILDX_BUILDER}" >/dev/null 2>&1; then
    docker buildx create --name "${BUILDX_BUILDER}" --driver docker-container >/dev/null
  fi

  # Реестр принимает манифест схемы v2, поэтому манифесты проверки
  # происхождения и состава пакетов не создаются.
  docker buildx build \
    --builder "${BUILDX_BUILDER}" \
    --provenance=false \
    --sbom=false \
    --build-arg "APP_VERSION=${APP_VERSION}" \
    --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --tag "${image}" \
    --push \
    "${ROOT_DIR}/app"

  BUILT_IMAGE="${image}"
}

app() {
  require_tool kubectl
  require_tool envsubst

  local ip app_host
  ip="$(ingress_ip)"
  app_host="app.${ip}.nip.io"

  build_and_push
  local image="${BUILT_IMAGE}"

  log "Развёртывание приложения ${image}"
  kubectl apply -f "${K8S_DIR}/namespace.yaml"

  # Реестр приватный, а узлы собраны на обычных машинах: права сервисного
  # аккаунта через метаданные экземпляра containerd не использует, поэтому
  # ключ доступа передаётся секретом.
  local key_file="${BOOTSTRAP_DIR}/terraform-sa-key.json"
  if [[ -f "${key_file}" ]]; then
    kubectl create secret docker-registry cr-credentials \
      -n "${APP_NAMESPACE}" \
      --docker-server=cr.yandex \
      --docker-username=json_key \
      --docker-password="$(cat "${key_file}")" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  else
    log "Ключ ${key_file} не найден: секрет доступа к реестру не обновлён"
  fi

  IMAGE="${image}" APP_HOST="${app_host}" \
    envsubst '${IMAGE} ${APP_HOST}' < "${K8S_DIR}/app/deployment.yaml" | kubectl apply -f -

  kubectl apply -f "${K8S_DIR}/app/service.yaml"
  kubectl apply -f "${K8S_DIR}/app/pdb.yaml"

  APP_HOST="${app_host}" envsubst '${APP_HOST}' < "${K8S_DIR}/app/ingress.yaml" | kubectl apply -f -

  kubectl -n "${APP_NAMESPACE}" rollout status "deployment/${APP_NAME}" --timeout=180s

  cat <<EOF

Приложение:  http://${app_host}/
Grafana:     http://grafana.${ip}.nip.io/  (пользователь admin, пароль из .env)
Prometheus:  kubectl port-forward -n ${MONITORING_NAMESPACE} svc/${MONITORING_RELEASE}-prometheus 9090:9090
EOF
}

status() {
  require_tool kubectl
  kubectl -n "${APP_NAMESPACE}" get pods,service,ingress
  kubectl -n "${MONITORING_NAMESPACE}" get pods
}

main() {
  load_env

  local stage="${1:-all}"
  case "${stage}" in
    bootstrap | infra | cluster | kubeconfig | ingress | monitoring | app | status | all) ;;
    *)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 1
      ;;
  esac

  if [[ "${stage}" != "status" ]]; then
    ensure_yc_auth
  fi

  case "${stage}" in
    bootstrap) bootstrap ;;
    infra) infra ;;
    cluster) cluster ;;
    kubeconfig) kubeconfig ;;
    ingress) ingress ;;
    monitoring) monitoring ;;
    app) app ;;
    status) status ;;
    all)
      log "Развёртывание проекта целиком"
      bootstrap
      infra
      cluster
      kubeconfig
      ingress
      monitoring
      app
      status
      ;;
  esac
}

main "$@"
