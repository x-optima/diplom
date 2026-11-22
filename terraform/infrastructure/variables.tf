variable "cloud_id" {
  description = "Идентификатор облака"
  type        = string
}

variable "folder_id" {
  description = "Идентификатор каталога"
  type        = string
}

variable "service_account_key_file" {
  description = "Ключ сервисного аккаунта Terraform, созданного на подготовительном этапе"
  type        = string
  default     = "../bootstrap/terraform-sa-key.json"
}

variable "zones" {
  description = "Зоны доступности для подсетей и узлов кластера"
  type        = list(string)
  default     = ["ru-central1-a", "ru-central1-b", "ru-central1-d"]
}

variable "name_prefix" {
  description = "Префикс в именах ресурсов"
  type        = string
  default     = "diplom"
}

variable "network_cidr" {
  description = "Диапазон адресов облачной сети"
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_prefix_length" {
  description = "Длина префикса подсети в каждой зоне"
  type        = number
  default     = 24
}

variable "cluster_version" {
  description = "Версия Kubernetes"
  type        = string
  default     = "1.31"
}

variable "node_platform_id" {
  description = "Платформа вычислительных узлов"
  type        = string
  default     = "standard-v3"
}

variable "node_cores" {
  description = "Количество ядер на узел"
  type        = number
  default     = 2
}

variable "node_memory" {
  description = "Объём памяти узла в гигабайтах"
  type        = number
  default     = 4
}

variable "node_core_fraction" {
  description = "Гарантированная доля процессора, процент"
  type        = number
  default     = 50
}

variable "node_disk_size" {
  description = "Размер загрузочного диска узла в гигабайтах"
  type        = number
  default     = 32
}

variable "node_count" {
  description = "Количество узлов по умолчанию и минимальное в группе"
  type        = number
  default     = 3
}

variable "node_max_count" {
  description = "Максимальное количество узлов при автомасштабировании"
  type        = number
  default     = 6
}

variable "ssh_public_key_path" {
  description = "Публичный SSH-ключ для доступа к узлам"
  type        = string
  default     = "~/.ssh/yandex.pub"
}

variable "registry_name" {
  description = "Имя реестра образов контейнеров"
  type        = string
  default     = "diplom-registry"
}

variable "k8s_service_account_name" {
  description = "Имя сервисного аккаунта мастера, созданного на подготовительном этапе"
  type        = string
  default     = "diplom-k8s-agent"
}

variable "nodes_service_account_name" {
  description = "Имя сервисного аккаунта узлов, созданного на подготовительном этапе"
  type        = string
  default     = "diplom-k8s-nodes"
}
