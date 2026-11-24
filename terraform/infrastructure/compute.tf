# Кластер собирается самостоятельно на виртуальных машинах Compute Cloud.
# Управляющая машина одна, рабочих две.
# Образ взят из семейства Debian 11: минимальный размер диска у него 3 ГБ,
# поэтому три машины укладываются в квоту на диски в зоне.

data "yandex_compute_image" "vm" {
  family    = var.vm_image_family
  folder_id = "standard-images"
}

data "yandex_iam_service_account" "nodes" {
  name      = var.nodes_service_account_name
  folder_id = var.folder_id
}

locals {
  # Все машины размещаются в первой зоне списка. Из ru-central1-d нет доступа
  # к registry.k8s.io: узлы не скачивают образы pause, kube-proxy и контроллера
  # ingress, из-за чего поды остаются в ImagePullBackOff.
  master_zone = var.zones[0]
  worker_zone = var.zones[0]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # cloud-init создаёт учётную запись с доступом к sudo без пароля:
  # kubeadm и установка пакетов требуют прав root.
  cloud_init = <<-EOT
    #cloud-config
    users:
      - name: ${var.vm_user}
        groups: sudo
        shell: /bin/bash
        sudo: ['ALL=(ALL) NOPASSWD:ALL']
        ssh_authorized_keys:
          - ${local.ssh_public_key}
    ssh_pwauth: false
    disable_root: true
  EOT
}

resource "yandex_compute_instance" "master" {
  name        = "${var.name_prefix}-master"
  description = "Управляющая машина кластера Kubernetes"
  platform_id = var.vm_platform_id
  zone        = local.master_zone

  resources {
    cores         = var.master_cores
    memory        = var.master_memory
    core_fraction = var.vm_core_fraction
  }

  boot_disk {
    initialize_params {
      # Диск HDD: у SSD квота в зоне вдвое меньше, а скорость для узла
      # кластера не критична.
      type     = "network-hdd"
      size     = var.master_disk_size
      image_id = data.yandex_compute_image.vm.id
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.main[local.master_zone].id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.k8s.id]
  }

  metadata = {
    user-data = local.cloud_init
  }

  service_account_id = data.yandex_iam_service_account.nodes.id

  scheduling_policy {
    preemptible = false
  }
}

resource "yandex_compute_instance" "worker" {
  count = var.worker_count

  name        = "${var.name_prefix}-worker-${count.index + 1}"
  description = "Рабочая машина кластера Kubernetes"
  platform_id = var.vm_platform_id
  zone        = local.worker_zone

  resources {
    cores         = var.worker_cores
    memory        = var.worker_memory
    core_fraction = var.vm_core_fraction
  }

  boot_disk {
    initialize_params {
      type     = "network-hdd"
      size     = var.worker_disk_size
      image_id = data.yandex_compute_image.vm.id
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.main[local.worker_zone].id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.k8s.id]
  }

  metadata = {
    user-data = local.cloud_init
  }

  service_account_id = data.yandex_iam_service_account.nodes.id

  # Рабочие машины прерываемые: это заметно дешевле, а остановка узла
  # не останавливает кластер.
  scheduling_policy {
    preemptible = true
  }
}

# Файл инвентаря для Ansible собирается из адресов, выданных облаком:
# управляющая машина входит в группу master, рабочие — в workers.
locals {
  # Содержимое вынесено в значение: пайплайн берёт его из выходов.
  ansible_inventory = templatefile("${path.module}/inventory.ini.tpl", {
    master_external = yandex_compute_instance.master.network_interface[0].nat_ip_address
    master_internal = yandex_compute_instance.master.network_interface[0].ip_address
    workers = [
      for instance in yandex_compute_instance.worker : {
        external = instance.network_interface[0].nat_ip_address
        internal = instance.network_interface[0].ip_address
      }
    ]
    vm_user = var.vm_user
  })
}

resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../../ansible/inventory.ini"
  content  = local.ansible_inventory
}
