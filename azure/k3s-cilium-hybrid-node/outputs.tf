output "vmss_name" {
  value = azurerm_linux_virtual_machine_scale_set.node.name
}

output "resource_group" {
  value = azurerm_resource_group.node.name
}

output "instances" {
  value = var.instances
}

output "managed_identity_principal_id" {
  description = "VMSS の System-assigned Managed Identity（RBAC ロール割当先。keyless）"
  value       = azurerm_linux_virtual_machine_scale_set.node.identity[0].principal_id
}
