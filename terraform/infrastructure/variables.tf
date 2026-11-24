# Переменные основной конфигурации. Значения задаются в terraform/terraform.tfvars,
# в пайплайне приходят через TF_VAR_*.

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

# Сеть: зоны задают набор подсетей, длина префикса — размер каждой из них.
variable "zones" {
  description = "Зоны доступности для подсетей и виртуальных машин"
  type        = list(string)
  default     = ["ru-central1-a", "ru-central1-d"]
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

# Машины кластера: образ, учётная запись и платформа. Доля процессора задаётся
# в процентах и влияет на стоимость сильнее числа ядер.
variable "vm_image_family" {
  description = "Семейство образа виртуальных машин кластера"
  type        = string
  default     = "debian-11"
}

variable "vm_user" {
  description = "Учётная запись, создаваемая в виртуальной машине"
  type        = string
  default     = "k8s"
}

variable "ssh_public_key_path" {
  description = "Публичный SSH-ключ для доступа к виртуальным машинам"
  type        = string
  default     = "~/.ssh/yandex.pub"
}

variable "vm_platform_id" {
  description = "Платформа виртуальных машин"
  type        = string
  default     = "standard-v3"
}

variable "vm_core_fraction" {
  description = "Гарантированная доля процессора, процент"
  type        = number
  default     = 20
}

# Ресурсы машин. Диски заданы отдельно: у управляющей машины нет рабочих
# нагрузок, поэтому ей хватает меньшего размера.
variable "master_cores" {
  description = "Количество ядер управляющей машины"
  type        = number
  default     = 2
}

variable "master_memory" {
  description = "Объём памяти управляющей машины в гигабайтах"
  type        = number
  default     = 2
}

variable "master_disk_size" {
  description = "Размер загрузочного диска управляющей машины в гигабайтах"
  type        = number
  default     = 4
}

variable "worker_count" {
  description = "Количество рабочих машин"
  type        = number
  default     = 2
}

variable "worker_cores" {
  description = "Количество ядер рабочей машины"
  type        = number
  default     = 2
}

variable "worker_memory" {
  description = "Объём памяти рабочей машины в гигабайтах"
  type        = number
  default     = 2
}

variable "worker_disk_size" {
  description = "Размер загрузочного диска рабочей машины в гигабайтах"
  type        = number
  default     = 7
}

variable "registry_name" {
  description = "Имя реестра образов контейнеров"
  type        = string
  default     = "diplom-registry"
}

variable "nodes_service_account_name" {
  description = "Имя сервисного аккаунта машин кластера, созданного на подготовительном этапе"
  type        = string
  default     = "diplom-k8s-nodes"
}
