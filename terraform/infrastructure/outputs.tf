output "network_id" {
  description = "Идентификатор облачной сети"
  value       = yandex_vpc_network.main.id
}

output "subnet_ids" {
  description = "Идентификаторы подсетей по зонам доступности"
  value       = { for zone, subnet in yandex_vpc_subnet.main : zone => subnet.id }
}

output "cluster_id" {
  description = "Идентификатор кластера Kubernetes"
  value       = yandex_kubernetes_cluster.main.id
}

output "cluster_external_endpoint" {
  description = "Внешний адрес API-сервера кластера"
  value       = yandex_kubernetes_cluster.main.master[0].external_v4_endpoint
}

output "cluster_ca_certificate" {
  description = "Сертификат удостоверяющего центра кластера"
  value       = yandex_kubernetes_cluster.main.master[0].cluster_ca_certificate
  sensitive   = true
}

output "node_group_id" {
  description = "Идентификатор группы узлов"
  value       = yandex_kubernetes_node_group.workers.id
}

output "registry_id" {
  description = "Идентификатор реестра образов"
  value       = yandex_container_registry.main.id
}

output "registry_address" {
  description = "Адрес реестра для тегов образов"
  value       = "cr.yandex/${yandex_container_registry.main.id}"
}

output "kubeconfig_command" {
  description = "Команда получения файла доступа к кластеру"
  value       = "yc managed-kubernetes cluster get-credentials ${yandex_kubernetes_cluster.main.name} --external --force"
}
