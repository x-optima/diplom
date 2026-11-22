output "terraform_service_account_id" {
  description = "Идентификатор сервисного аккаунта Terraform"
  value       = yandex_iam_service_account.terraform.id
}

output "k8s_service_account_id" {
  description = "Идентификатор сервисного аккаунта мастера Kubernetes"
  value       = yandex_iam_service_account.k8s.id
}

output "nodes_service_account_id" {
  description = "Идентификатор сервисного аккаунта рабочих узлов"
  value       = yandex_iam_service_account.nodes.id
}

output "state_bucket" {
  description = "Имя бакета с файлом состояния"
  value       = yandex_storage_bucket.state.bucket
}

output "state_backend_endpoint" {
  description = "Endpoint S3 для настройки backend"
  value       = "https://storage.yandexcloud.net"
}

output "terraform_key_file" {
  description = "Путь к сохранённому ключу сервисного аккаунта Terraform"
  value       = local_sensitive_file.terraform_key.filename
}
