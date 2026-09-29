output "asg_name" {
  description = "Auto Scaling Group 名"
  value       = aws_autoscaling_group.node.name
}

output "launch_template_id" {
  description = "Launch Template ID"
  value       = aws_launch_template.node.id
}

output "instance_types" {
  description = "Spot 候補 instance タイプ群"
  value       = var.instance_types
}

output "availability_zones" {
  description = "Spot を分散する AZ (subnet) 群"
  value       = local.subnet_ids
}

output "security_group_id" {
  value = aws_security_group.node.id
}

output "node_name" {
  description = "k3s node 名"
  value       = var.node_name
}

output "node_iam_role" {
  description = "ノードに付与された IAM ロール（pod は IMDS 経由で assume）"
  value       = aws_iam_role.node.name
}

output "node_instance_profile" {
  value = aws_iam_instance_profile.node.name
}
