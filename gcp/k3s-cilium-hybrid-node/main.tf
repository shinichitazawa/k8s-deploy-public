# default compute SA（var 未指定時に使用）
data "google_compute_default_service_account" "default" {}

locals {
  sa_email = var.service_account_email != "" ? var.service_account_email : data.google_compute_default_service_account.default.email

  startup_script = templatefile("${path.module}/templates/startup-script.sh.tftpl", {
    node_name         = var.node_name
    tailscale_authkey = var.tailscale_authkey
    k3s_cp_host       = var.k3s_cp_host
    k3s_cp_port       = var.k3s_cp_port
    k3s_url           = "https://${var.k3s_cp_host}:${var.k3s_cp_port}"
    k3s_version       = var.k3s_version
    k3s_token         = var.k3s_token
    node_taint        = var.node_taint
  })
}

# 専用 VPC + subnet。ingress firewall を作らない＝GCP 既定の deny-all-ingress で egress-only。
# egress は implied-allow + default-internet-gateway route で確保（stateful なので Tailscale 直結OK）。
resource "google_compute_network" "node" {
  name                    = "${var.node_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "node" {
  name          = "${var.node_name}-subnet"
  network       = google_compute_network.node.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr
}

# public_ip=false(完全 private)時の outbound。nat_type で方式を選ぶ。
locals {
  gw_nat  = !var.public_ip && var.nat_type == "gateway"
  vm_nat  = !var.public_ip && var.nat_type == "instance"
  nat_tag = "${var.node_name}-private"
}

# --- nat_type="gateway": マネージド Cloud NAT ---
resource "google_compute_router" "node" {
  count   = local.gw_nat ? 1 : 0
  name    = "${var.node_name}-router"
  region  = var.region
  network = google_compute_network.node.id
}

resource "google_compute_router_nat" "node" {
  count                              = local.gw_nat ? 1 : 0
  name                               = "${var.node_name}-nat"
  router                             = google_compute_router.node[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# --- nat_type="instance"(既定): 小型 NAT VM(Cloud NAT より桁安) ---
# 外部IP付き VM 1台で ip_forward + iptables MASQUERADE。private ノードは
# next-hop=この VM のルートで egress する。NAT GW の固定 $32/月に対し e2-micro は無料枠圏。
resource "google_compute_firewall" "nat_from_subnet" {
  count     = local.vm_nat ? 1 : 0
  name      = "${var.node_name}-nat-in"
  network   = google_compute_network.node.id
  direction = "INGRESS"
  allow {
    protocol = "all"
  }
  source_ranges = [var.subnet_cidr]
  target_tags   = ["${var.node_name}-nat"]
}

resource "google_compute_instance" "nat" {
  count          = local.vm_nat ? 1 : 0
  name           = "${var.node_name}-nat"
  machine_type   = "e2-micro"
  zone           = var.zone
  can_ip_forward = true
  tags           = ["${var.node_name}-nat"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.node.id
    access_config {} # NAT VM 自身は外部IP(egress の出口)
  }
  metadata_startup_script = <<-EOT
    #!/bin/bash
    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-nat.conf
    IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
  EOT
  scheduling {
    preemptible       = false
    automatic_restart = true
  }
}

resource "google_compute_route" "nat" {
  count             = local.vm_nat ? 1 : 0
  name              = "${var.node_name}-nat-route"
  network           = google_compute_network.node.id
  dest_range        = "0.0.0.0/0"
  next_hop_instance = google_compute_instance.nat[0].self_link
  priority          = 800 # default-internet-gateway(1000)より優先
  tags              = [local.nat_tag]
}

# Instance Template（Spot / Ubuntu / startup-script / SA / 外部IP=egress用）
resource "google_compute_instance_template" "node" {
  name_prefix  = "${var.node_name}-"
  machine_type = var.machine_type
  # nat_type="instance" 時のルート対象タグ(public/gateway 時は無害)
  tags = [local.nat_tag]

  disk {
    source_image = var.image
    auto_delete  = true
    boot         = true
    disk_size_gb = 10
    disk_type    = "pd-standard"
  }

  network_interface {
    network    = google_compute_network.node.id
    subnetwork = google_compute_subnetwork.node.id
    # public_ip=true: ephemeral 外部IP で egress(ingress は firewall 無しで implied deny)。
    # public_ip=false: 完全 private(外部IP無し)。egress は Cloud NAT 経由。
    dynamic "access_config" {
      for_each = var.public_ip ? [1] : []
      content {}
    }
  }

  metadata = {
    startup-script = local.startup_script
  }

  service_account {
    email  = local.sa_email
    scopes = var.scopes
  }

  # Spot: MIG では termination action=STOP 必須（DELETE 不可）。preempt 時は STOP→MIG が自己修復
  scheduling {
    provisioning_model          = "SPOT"
    preemptible                 = true
    automatic_restart           = false
    instance_termination_action = "STOP"
  }

  labels = {
    purpose = "k3s-cilium-hybrid"
    cloud   = "gcp"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Zonal MIG。cluster-autoscaler(GCE provider)が target_size を管理。
# ★ regional ではなく zonal。GCE CA は zonal MIG の URL(.../zones/<zone>/instanceGroups/<name>)
#   しか parse できず、regional URL(.../regions/<region>/…)を "wrong url" で拒否するため
#   (2026-07 live 検証で確認)。トレードオフ: Spot 在庫は var.zone 単一ゾーンに限られる。
resource "google_compute_instance_group_manager" "node" {
  name               = "${var.node_name}-mig"
  base_instance_name = var.node_name
  zone               = var.zone

  version {
    instance_template = google_compute_instance_template.node.id
  }

  # ゼロスケール: 運用時は 0（CA が pending pod で増やす）。テスト時は 1。
  target_size = var.target_size

  update_policy {
    type                  = "OPPORTUNISTIC"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1 # zonal: 1 で十分
    max_unavailable_fixed = 0
  }

  lifecycle {
    # cluster-autoscaler / 手動で target_size を変えても TF が戻さない
    ignore_changes = [target_size]
  }
}
