terraform {
  required_version = ">= 1.9.0"

  # Параметры хранилища состояния передаются при инициализации:
  # terraform init -backend-config=backend.hcl
  backend "s3" {}

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.213.0"
    }
  }
}

provider "yandex" {
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = var.zones[0]
  service_account_key_file = pathexpand(var.service_account_key_file)
}
