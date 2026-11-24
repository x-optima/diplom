# Выходы читают скрипты развёртывания и пайплайн: адреса машин нужны для
# доступа к кластеру и для имён хостов, инвентарь — для Ansible.

output "network_id" {
  description = "Идентификатор облачной сети"
  value       = yandex_vpc_network.main.id
}

output "subnet_ids" {
  description = "Идентификаторы подсетей по зонам доступности"
  value       = { for zone, subnet in yandex_vpc_subnet.main : zone => subnet.id }
}

output "master_external_ip" {
  description = "Внешний адрес управляющей машины"
  value       = yandex_compute_instance.master.network_interface[0].nat_ip_address
}

output "master_internal_ip" {
  description = "Внутренний адрес управляющей машины"
  value       = yandex_compute_instance.master.network_interface[0].ip_address
}

output "worker_external_ips" {
  description = "Внешние адреса рабочих машин"
  value       = [for instance in yandex_compute_instance.worker : instance.network_interface[0].nat_ip_address]
}

output "worker_internal_ips" {
  description = "Внутренние адреса рабочих машин"
  value       = [for instance in yandex_compute_instance.worker : instance.network_interface[0].ip_address]
}

output "ansible_inventory" {
  description = "Путь к файлу инвентаря Ansible"
  value       = local_file.ansible_inventory.filename
}

output "ansible_inventory_content" {
  description = "Содержимое инвентаря Ansible"
  value       = local.ansible_inventory
}

output "registry_id" {
  description = "Идентификатор реестра образов"
  value       = yandex_container_registry.main.id
}

output "registry_address" {
  description = "Адрес реестра для тегов образов"
  value       = "cr.yandex/${yandex_container_registry.main.id}"
}
