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

      # egress(tailscale/k3s install)用に per-instance public IP
      public_ip_address {
        name = "${var.node_name}-pip"
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
