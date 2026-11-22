#!/usr/bin/env bash
#
# Развёртывание дипломного проекта.
#
#   ./scripts/deploy.sh bootstrap    подготовительный этап: сервисные аккаунты и бакет
#   ./scripts/deploy.sh infra        сеть, кластер Kubernetes, реестр образов
#   ./scripts/deploy.sh kubeconfig   файл доступа к кластеру в ~/.kube/config
#   ./scripts/deploy.sh ingress      контроллер ingress-nginx с внешним балансировщиком
#   ./scripts/deploy.sh monitoring   Prometheus, Grafana, Alertmanager, node-exporter
#   ./scripts/deploy.sh app          сборка образа и развёртывание приложения
#   ./scripts/deploy.sh all          этапы infra -> kubeconfig -> ingress -> monitoring -> app

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/terraform/infrastructure"
BOOTSTRAP_DIR="${ROOT_DIR}/terraform/bootstrap"
K8S_DIR="${ROOT_DIR}/k8s"

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
  if [[ -f "${ROOT_DIR}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/.env"
    set +a
  fi
  GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"
  APP_VERSION="${APP_VERSION:-latest}"
}

bootstrap() {
  require_tool terraform
  log "Подготовительный этап: сервисные аккаунты и бакет состояния"
  terraform -chdir="${BOOTSTRAP_DIR}" init -input=false
  terraform -chdir="${BOOTSTRAP_DIR}" apply -input=false
}

infra() {
  require_tool terraform
  [[ -f "${INFRA_DIR}/backend.hcl" ]] || die "создайте terraform/infrastructure/backend.hcl по образцу backend.hcl.example"
  [[ -f "${INFRA_DIR}/terraform.tfvars" ]] || die "создайте terraform/infrastructure/terraform.tfvars по образцу terraform.tfvars.example"

  log "Создание сети, кластера и реестра образов"
  terraform -chdir="${INFRA_DIR}" init -input=false -backend-config=backend.hcl
  terraform -chdir="${INFRA_DIR}" apply -input=false
}

kubeconfig() {
  require_tool yc
  require_tool kubectl
  local cluster_id
  cluster_id="$(terraform -chdir="${INFRA_DIR}" output -raw cluster_id)"
  log "Получение файла доступа к кластеру ${cluster_id}"
  yc managed-kubernetes cluster get-credentials "${cluster_id}" --external --force
  kubectl get nodes -o wide
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

wait_for_load_balancer() {
  local attempt ip
  for attempt in $(seq 1 60); do
    ip="$(kubectl -n ingress-nginx get service ingress-nginx-controller \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s' "${ip}"
      return 0
    fi
    sleep 10
  done
  die "балансировщик не получил внешний адрес"
}

monitoring() {
  require_tool helm
  [[ -n "${GRAFANA_PASSWORD}" ]] || die "задайте GRAFANA_PASSWORD в файле .env"

  local ip grafana_host
  ip="$(wait_for_load_balancer)"
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

build_and_push() {
  require_tool docker
  require_tool yc

  local registry_id image
  registry_id="$(terraform -chdir="${INFRA_DIR}" output -raw registry_id)"
  image="cr.yandex/${registry_id}/${APP_NAME}:${APP_VERSION}"

  log "Сборка образа ${image}"
  yc container registry configure-docker >/dev/null
  docker build \
    --build-arg "APP_VERSION=${APP_VERSION}" \
    --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --tag "${image}" \
    "${ROOT_DIR}/app"
  docker push "${image}"

  BUILT_IMAGE="${image}"
}

app() {
  require_tool kubectl
  require_tool envsubst

  local ip app_host
  ip="$(wait_for_load_balancer)"
  app_host="app.${ip}.nip.io"

  build_and_push
  local image="${BUILT_IMAGE}"

  log "Развёртывание приложения ${image}"
  kubectl apply -f "${K8S_DIR}/namespace.yaml"

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
  case "${1:-}" in
    bootstrap) bootstrap ;;
    infra) infra ;;
    kubeconfig) kubeconfig ;;
    ingress) ingress ;;
    monitoring) monitoring ;;
    app) app ;;
    status) status ;;
    all)
      infra
      kubeconfig
      ingress
      monitoring
      app
      ;;
    *)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 1
      ;;
  esac
}

main "$@"
