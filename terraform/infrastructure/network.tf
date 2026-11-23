locals {
  # Каждой зоне доступности соответствует отдельная подсеть с собственным
  # диапазоном внутри сети. Номер диапазона берётся из постоянного списка зон,
  # а не из позиции в переменной: иначе удаление одной зоны из списка сдвигало
  # бы адреса остальных подсетей, а менять диапазон существующей подсети нельзя.
  zone_order     = ["ru-central1-a", "ru-central1-b", "ru-central1-d"]
  subnet_newbits = var.subnet_prefix_length - tonumber(split("/", var.network_cidr)[1])
  subnets = {
    for zone in var.zones :
    zone => cidrsubnet(var.network_cidr, local.subnet_newbits, index(local.zone_order, zone))
  }
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

# Правила для машин кластера: доступ по SSH, обмен трафиком внутри сети,
# API-сервер Kubernetes и диапазон портов NodePort для приложения.
resource "yandex_vpc_security_group" "k8s" {
  name        = "${var.name_prefix}-k8s"
  description = "Правила для машин кластера Kubernetes"
  network_id  = yandex_vpc_network.main.id

  ingress {
    description    = "SSH для обслуживания машин"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "API-сервер Kubernetes"
    protocol       = "TCP"
    port           = 6443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "HTTP к приложению и Grafana"
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "HTTPS"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Порты NodePort для служб кластера"
    protocol       = "TCP"
    from_port      = 30000
    to_port        = 32767
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Обмен трафиком внутри сети кластера"
    protocol       = "ANY"
    v4_cidr_blocks = [var.network_cidr]
  }

  ingress {
    description    = "Диагностические сообщения ICMP"
    protocol       = "ICMP"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Исходящий трафик"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}
