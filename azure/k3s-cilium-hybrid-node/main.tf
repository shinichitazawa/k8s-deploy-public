locals {
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

  # Cluster Autoscaler の scale-from-0 用 node-template タグ。
  # 0 台のとき CA は「増設される node の label/taint」を VMSS タグから読み、pending pod を賄えるか判断する。
  # Azure はタグ名に "/" を使えないため、AWS 規約の "k8s.io/cluster-autoscaler/..." を "_" に置換する。
  #   label: k8s.io_cluster-autoscaler_node-template_label_<key> = <value>
  #   taint: k8s.io_cluster-autoscaler_node-template_taint_<key> = <value>:<effect>
  # ref: https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler/cloudprovider/azure
  # ※ 値は startup-script.sh.tftpl の --node-label / --node-taint と必ず一致させること。
  ca_node_template_tags = merge(
    {
      "k8s.io_cluster-autoscaler_node-template_label_cloud" = "azure"
      "k8s.io_cluster-autoscaler_node-template_label_role"  = "azure-spot"
    },
    var.node_taint == "" ? {} : {
      "k8s.io_cluster-autoscaler_node-template_taint_${split("=", var.node_taint)[0]}" = split("=", var.node_taint)[1]
    }
  )
}

resource "azurerm_resource_group" "node" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "node" {
  name                = "${var.node_name}-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.node.name
  address_space       = [var.vnet_cidr]
}

resource "azurerm_subnet" "node" {
  name                 = "${var.node_name}-subnet"
  resource_group_name  = azurerm_resource_group.node.name
  virtual_network_name = azurerm_virtual_network.node.name
  address_prefixes     = [var.subnet_cidr]
}

# NSG: public IP のノードへの inbound を絞る。VMSS 起動時に付く public IP は
# 起動時 outbound(Tailscale/イメージ取得)のためだけで、クラスタ通信は Tailscale
# overlay 経由。よって inbound は Tailscale WireGuard(UDP 41641) と SSH(fallback,
# 自 CIDR のみ) だけ許可し、他は NSG 既定の DenyAllInBound で遮断する。
# NSG は stateful なので outbound-initiated の戻りは自動許可される。
resource "azurerm_network_security_group" "node" {
  name                = "${var.node_name}-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.node.name

  security_rule {
    name                       = "allow-tailscale-wireguard"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "41641"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-ssh-fallback"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.ssh_ingress_cidrs
    destination_address_prefix = "*"
  }
  # その他 inbound は NSG 既定の DenyAllInBound(65500) で遮断される。
}

resource "azurerm_subnet_network_security_group_association" "node" {
  subnet_id                 = azurerm_subnet.node.id
  network_security_group_id = azurerm_network_security_group.node.id
}

# public_ip=false(完全 private)時の outbound。nat_type で方式を選ぶ。
locals {
  gw_nat = !var.public_ip && var.nat_type == "gateway"
  vm_nat = !var.public_ip && var.nat_type == "instance"
}

# --- nat_type="gateway": マネージド NAT Gateway ---
resource "azurerm_public_ip" "nat" {
  count               = local.gw_nat ? 1 : 0
  name                = "${var.node_name}-nat-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.node.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "node" {
  count               = local.gw_nat ? 1 : 0
  name                = "${var.node_name}-natgw"
  location            = var.location
  resource_group_name = azurerm_resource_group.node.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "node" {
  count                = local.gw_nat ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.node[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "node" {
  count          = local.gw_nat ? 1 : 0
  subnet_id      = azurerm_subnet.node.id
  nat_gateway_id = azurerm_nat_gateway.node[0].id
}

# --- nat_type="instance"(既定): 小型 NAT VM(B1s)。NAT GW の固定費より桁安 ---
resource "azurerm_public_ip" "nat_vm" {
  count               = local.vm_nat ? 1 : 0
  name                = "${var.node_name}-natvm-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.node.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "nat" {
  count                 = local.vm_nat ? 1 : 0
  name                  = "${var.node_name}-natvm-nic"
  location              = var.location
  resource_group_name   = azurerm_resource_group.node.name
  ip_forwarding_enabled = true
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.node.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.nat_vm[0].id
  }
}

resource "azurerm_linux_virtual_machine" "nat" {
  count                 = local.vm_nat ? 1 : 0
  name                  = "${var.node_name}-natvm"
  location              = var.location
  resource_group_name   = azurerm_resource_group.node.name
  size                  = "Standard_B1s"
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.nat[0].id]
  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
  custom_data = base64encode(<<-EOT
    #!/bin/bash
    sysctl -w net.ipv4.ip_forward=1
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-nat.conf
    IFACE=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
  EOT
  )
}

resource "azurerm_route_table" "node" {
  count               = local.vm_nat ? 1 : 0
  name                = "${var.node_name}-rt"
  location            = var.location
  resource_group_name = azurerm_resource_group.node.name
}

resource "azurerm_route" "nat" {
  count                  = local.vm_nat ? 1 : 0
  name                   = "default-via-nat"
  resource_group_name    = azurerm_resource_group.node.name
  route_table_name       = azurerm_route_table.node[0].name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_network_interface.nat[0].private_ip_address
}

resource "azurerm_subnet_route_table_association" "node" {
  count          = local.vm_nat ? 1 : 0
  subnet_id      = azurerm_subnet.node.id
  route_table_id = azurerm_route_table.node[0].id
}

# VMSS（AWS ASG / GCP MIG / OCI Instance Pool 相当）+ Spot + System-assigned Managed Identity(keyless)
resource "azurerm_linux_virtual_machine_scale_set" "node" {
  name                = "${var.node_name}-vmss"
  resource_group_name = azurerm_resource_group.node.name
  location            = var.location
  sku                 = var.vm_size
  instances           = var.instances
  admin_username      = var.admin_username

  # Spot: 最大 on-demand 価格まで、退避時は削除（MIG 相当の自己修復）
  priority        = "Spot"
  eviction_policy = "Delete"
  max_bid_price   = -1

  # Managed Identity: pod は IMDS 経由でこの ID を assume して Azure を操作（AWS instance profile 相当）
  identity {
    type = "SystemAssigned"
  }

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  custom_data = base64encode(local.startup_script)

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = var.image_sku
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  network_interface {
    name    = "${var.node_name}-nic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.node.id

      # public_ip=true: egress(tailscale/k3s install)用に per-instance public IP。
      # public_ip=false: 完全 private。egress は下の NAT Gateway 経由。
      dynamic "public_ip_address" {
        for_each = var.public_ip ? [1] : []
        content {
          name = "${var.node_name}-pip"
        }
      }
    }
  }

  # CA scale-from-0 用の node-template タグ（詳細は locals.ca_node_template_tags のコメント参照）。
  # これまで live 側に手動付与していたものを codify し、drift を解消する。
  tags = local.ca_node_template_tags

  lifecycle {
    # cluster-autoscaler / 手動で instances を変えても TF が戻さない（ゼロスケール）
    ignore_changes = [instances]
  }
}
