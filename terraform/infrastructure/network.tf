locals {
  # Каждой зоне доступности соответствует отдельная подсеть с собственным
  # диапазоном внутри сети. Номер подсети определяется порядком зоны в списке.
  subnet_newbits = var.subnet_prefix_length - tonumber(split("/", var.network_cidr)[1])
  subnets = {
    for index, zone in var.zones :
    zone => cidrsubnet(var.network_cidr, local.subnet_newbits, index)
  }

  # Адреса проверки состояния от балансировщика Yandex Cloud.
  healthcheck_cidrs = ["198.18.235.0/24", "198.18.248.0/24"]
}

resource "yandex_vpc_network" "main" {
  name        = "${var.name_prefix}-network"
  description = "Сеть дипломного проекта"
}

resource "yandex_vpc_subnet" "main" {
  for_each = local.subnets

  name           = "${var.name_prefix}-subnet-${each.key}"
  zone           = each.key
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = [each.value]
}

resource "yandex_vpc_security_group" "nodes" {
  name        = "${var.name_prefix}-k8s-nodes"
  description = "Правила для рабочих узлов кластера"
  network_id  = yandex_vpc_network.main.id

  ingress {
    description    = "SSH для обслуживания узлов"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Обмен трафиком внутри сети кластера"
    protocol       = "ANY"
    v4_cidr_blocks = [var.network_cidr]
  }

  ingress {
    description    = "Проверка состояния узлов балансировщиком"
    protocol       = "TCP"
    from_port      = 30000
    to_port        = 32767
    v4_cidr_blocks = local.healthcheck_cidrs
  }

  ingress {
    description    = "Диагностические сообщения ICMP"
    protocol       = "ICMP"
    v4_cidr_blocks = [var.network_cidr]
  }

  egress {
    description    = "Исходящий трафик"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_vpc_security_group" "master" {
  name        = "${var.name_prefix}-k8s-master"
  description = "Правила для мастера кластера"
  network_id  = yandex_vpc_network.main.id

  ingress {
    description    = "API-сервер Kubernetes"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "API-сервер Kubernetes, порт 6443"
    protocol       = "TCP"
    port           = 6443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Обмен трафиком с узлами"
    protocol       = "ANY"
    v4_cidr_blocks = [var.network_cidr]
  }

  egress {
    description    = "Исходящий трафик"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
