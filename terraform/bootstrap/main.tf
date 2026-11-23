locals {
  terraform_sa_name = "${var.name_prefix}-terraform"
  nodes_sa_name     = "${var.name_prefix}-k8s-nodes"

  terraform_sa_roles = [
    "editor",
    "storage.admin",
  ]

  k8s_nodes_roles = [
    "container-registry.images.puller",
    "logging.writer",
    "monitoring.editor",
  ]
}

resource "yandex_iam_service_account" "terraform" {
  name        = local.terraform_sa_name
  description = "Сервисный аккаунт для управления инфраструктурой из Terraform"
}

resource "yandex_iam_service_account" "nodes" {
  name        = local.nodes_sa_name
  description = "Сервисный аккаунт машин кластера: загрузка образов и телеметрия"
}

resource "yandex_resourcemanager_folder_iam_member" "terraform" {
  for_each = toset(local.terraform_sa_roles)

  folder_id = var.folder_id
  role      = each.value
  member    = "serviceAccount:${yandex_iam_service_account.terraform.id}"
}

resource "yandex_resourcemanager_folder_iam_member" "k8s_nodes" {
  for_each = toset(local.k8s_nodes_roles)

  folder_id = var.folder_id
  role      = each.value
  member    = "serviceAccount:${yandex_iam_service_account.nodes.id}"
}

resource "yandex_iam_service_account_key" "terraform" {
  service_account_id = yandex_iam_service_account.terraform.id
  description        = "Ключ для Terraform и пайплайна инфраструктуры"
  key_algorithm      = "RSA_4096"
}

resource "local_sensitive_file" "terraform_key" {
  filename        = "${path.module}/terraform-sa-key.json"
  file_permission = "0600"
  content = jsonencode({
    id                 = yandex_iam_service_account_key.terraform.id
    service_account_id = yandex_iam_service_account.terraform.id
    created_at         = yandex_iam_service_account_key.terraform.created_at
    key_algorithm      = yandex_iam_service_account_key.terraform.key_algorithm
    public_key         = yandex_iam_service_account_key.terraform.public_key
    private_key        = yandex_iam_service_account_key.terraform.private_key
  })
}

# Случайный суффикс имени бакета: имя должно быть уникальным во всём Object
# Storage, а идентификаторы каталога и облака в имени не нужны.
resource "random_id" "bucket" {
  byte_length = 4
}

locals {
  state_bucket_name = var.state_bucket_name != "" ? var.state_bucket_name : "${var.name_prefix}-tfstate-${random_id.bucket.hex}"
}

resource "yandex_storage_bucket" "state" {
  bucket        = local.state_bucket_name
  folder_id     = var.folder_id
  max_size      = var.state_bucket_max_size
  force_destroy = true

  versioning {
    enabled = true
  }

  anonymous_access_flags {
    read = false
    list = false
  }
}
