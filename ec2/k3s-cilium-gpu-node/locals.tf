locals {
  k3s_url = "https://${var.k3s_cp_host}:${var.k3s_cp_port}"

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    node_name         = var.node_name
    tailscale_authkey = var.tailscale_authkey
    k3s_cp_host       = var.k3s_cp_host
    k3s_cp_port       = var.k3s_cp_port
    k3s_url           = local.k3s_url
    k3s_version       = var.k3s_version
    k3s_token         = var.k3s_token
    node_taint        = var.node_taint
  })
}
