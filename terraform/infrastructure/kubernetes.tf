data "yandex_iam_service_account" "k8s" {
  name      = var.k8s_service_account_name
  folder_id = var.folder_id
}

data "yandex_iam_service_account" "nodes" {
  name      = var.nodes_service_account_name
  folder_id = var.folder_id
}

resource "yandex_kubernetes_cluster" "main" {
  name        = "${var.name_prefix}-cluster"
  description = "Региональный кластер Kubernetes дипломного проекта"

  network_id = yandex_vpc_network.main.id

  service_account_id      = data.yandex_iam_service_account.k8s.id
  node_service_account_id = data.yandex_iam_service_account.nodes.id

  release_channel         = "STABLE"
  network_policy_provider = "CALICO"

  cluster_ipv4_range = "10.100.0.0/16"
  service_ipv4_range = "10.200.0.0/16"

  master {
    version = var.cluster_version

    # Региональный мастер размещается в трёх зонах: при отказе одной зоны
    # управляющий слой остаётся доступен.
    regional {
      region = "ru-central1"

      dynamic "location" {
        for_each = var.zones
        content {
          zone = location.value
        }
      }
    }

    public_ip = true

    security_group_ids = [yandex_vpc_security_group.master.id]

    maintenance_policy {
      auto_upgrade = true

      maintenance_window {
        day        = "sunday"
        start_time = "23:00"
        duration   = "3h"
      }
    }
  }

  timeouts {
    create = "60m"
    update = "120m"
    delete = "30m"
  }
}

resource "yandex_kubernetes_node_group" "workers" {
  cluster_id = yandex_kubernetes_cluster.main.id
  name       = "${var.name_prefix}-workers"
  version    = var.cluster_version

  instance_template {
    platform_id = var.node_platform_id

    resources {
      cores         = var.node_cores
      memory        = var.node_memory
      core_fraction = var.node_core_fraction
    }

    boot_disk {
      type = "network-ssd"
      size = var.node_disk_size
    }

    network_interface {
      nat                = true
      subnet_ids         = [for subnet in yandex_vpc_subnet.main : subnet.id]
      security_group_ids = [yandex_vpc_security_group.nodes.id]
    }

    container_runtime {
      type = "containerd"
    }

    scheduling_policy {
      preemptible = true
    }

    metadata = {
      ssh-keys = "ubuntu:${file(pathexpand(var.ssh_public_key_path))}"
    }
  }

  scale_policy {
    auto_scale {
      min     = var.node_count
      max     = var.node_max_count
      initial = var.node_count
    }
  }

  allocation_policy {
    dynamic "location" {
      for_each = var.zones
      content {
        zone = location.value
      }
    }
  }

  maintenance_policy {
    auto_upgrade = true
    auto_repair  = true
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }
}
