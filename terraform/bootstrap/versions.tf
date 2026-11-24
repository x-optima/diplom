terraform {
  required_version = ">= 1.9.0"

  # yandex — облачные ресурсы, local — запись ключа на диск,
  # random — суффикс имени бакета.
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.213.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Пустой путь к ключу оставляет авторизацию из окружения: для первого запуска
# ключа сервисного аккаунта ещё нет, его создаёт этот же этап.
provider "yandex" {
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = var.zone
  service_account_key_file = var.service_account_key_file == "" ? null : pathexpand(var.service_account_key_file)
}
