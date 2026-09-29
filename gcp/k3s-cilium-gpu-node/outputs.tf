output "mig_name" {
  description = "Zonal MIG 名"
  value       = google_compute_instance_group_manager.node.name
}

output "mig_zone" {
  description = "MIG のゾーン(CA gce.conf の local-zone に一致させる)"
  value       = var.zone
}

output "instance_template" {
  value = google_compute_instance_template.node.name
}

output "region" {
  value = var.region
}

output "service_account" {
  description = "VM にアタッチした SA（ワークロードが metadata 経由で利用）"
  value       = local.sa_email
}

output "target_size" {
  value = var.target_size
}
