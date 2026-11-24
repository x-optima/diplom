# Переменные подготовительного этапа: облако, каталог и параметры хранилища
# состояния. Значения задаются в terraform/terraform.tfvars.

variable "cloud_id" {
  description = "Идентификатор облака Yandex Cloud"
  type        = string
}

variable "folder_id" {
  description = "Идентификатор каталога, в котором создаются ресурсы"
  type        = string
}

variable "zone" {
  description = "Зона доступности по умолчанию для провайдера"
  type        = string
  default     = "ru-central1-a"
}

variable "service_account_key_file" {
  description = "Путь к ключу сервисного аккаунта с правами администратора каталога. Если пусто, используется IAM-токен из окружения"
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Префикс в именах ресурсов"
  type        = string
  default     = "diplom"
}

variable "state_bucket_name" {
  description = "Имя бакета для файла состояния; пустое значение даёт имя со случайным суффиксом"
  type        = string
  default     = ""
}

variable "state_bucket_max_size" {
  description = "Ограничение размера бакета состояния в байтах"
  type        = number
  default     = 1073741824
}
