# Реестр образов. Адрес для тегов выдаёт выход registry_address в виде
# cr.yandex/<идентификатор>.
resource "yandex_container_registry" "main" {
  name      = var.registry_name
  folder_id = var.folder_id
}

# Машины кластера загружают образы приложения из реестра.
resource "yandex_container_registry_iam_binding" "puller" {
  registry_id = yandex_container_registry.main.id
  role        = "container-registry.images.puller"

  members = [
    "serviceAccount:${data.yandex_iam_service_account.nodes.id}",
  ]
}
