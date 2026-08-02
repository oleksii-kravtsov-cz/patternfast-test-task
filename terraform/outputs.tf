

output "vpc_id" {
  description = "vpc id"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "public subnets"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "private app subnets"
  value       = aws_subnet.private_app[*].id
}

output "private_data_subnet_ids" {
  description = "private data subnets"
  value       = aws_subnet.private_data[*].id
}

output "node_security_group_id" {
  description = "node security group"
  value       = aws_security_group.k3s_node.id
}

output "rds_security_group_id" {
  description = "database security group"
  value       = aws_security_group.rds.id
}

output "rds_instance_arn" {
  description = "rds arn"
  value       = aws_db_instance.billing.arn
}

output "rds_instance_identifier" {
  description = "rds identifier"
  value       = aws_db_instance.billing.identifier
}

output "rds_endpoint" {
  description = "rds endpoint"
  value       = aws_db_instance.billing.endpoint
}

output "rds_port" {
  description = "rds port"
  value       = aws_db_instance.billing.port
}

output "rds_master_user_secret_arn" {
  description = "rds master secret arn"
  value       = aws_db_instance.billing.master_user_secret[0].secret_arn
}

output "rds_storage_encrypted" {
  description = "rds storage encrypted"
  value       = aws_db_instance.billing.storage_encrypted
}

output "billing_exports_bucket_name" {
  description = "exports bucket name"
  value       = aws_s3_bucket.billing_exports.bucket
}

output "billing_exports_bucket_arn" {
  description = "exports bucket arn"
  value       = aws_s3_bucket.billing_exports.arn
}

output "access_logs_bucket_arn" {
  description = "access log bucket arn"
  value       = aws_s3_bucket.access_logs.arn
}

output "github_build_role_arn" {
  description = "build role arn"
  value       = aws_iam_role.github_build.arn
}

output "github_deploy_role_arn" {
  description = "deploy role arn"
  value       = aws_iam_role.github_deploy.arn
}

output "billing_service_role_arn" {
  description = "workload role arn"
  value       = aws_iam_role.billing_service.arn
}

output "node_instance_role_arn" {
  description = "node instance role arn"
  value       = aws_iam_role.k3s_node.arn
}

output "rds_monitoring_role_arn" {
  description = "rds monitoring role arn"
  value       = aws_iam_role.rds_monitoring.arn
}

output "kms_data_key_arn" {
  description = "data kms key arn"
  value       = aws_kms_key.data.arn
}

output "kms_logs_key_arn" {
  description = "logs kms key arn"
  value       = aws_kms_key.logs.arn
}

output "app_secret_arn" {
  description = "app secret arn"
  value       = aws_secretsmanager_secret.billing_service.arn
}

output "kubeconfig_secret_arn" {
  description = "kubeconfig secret arn"
  value       = aws_secretsmanager_secret.kubeconfig.arn
}

output "ecr_repository_url" {
  description = "ecr repository url"
  value       = aws_ecr_repository.billing_service.repository_url
}

output "node_instance_id" {
  description = "node instance id"
  value       = aws_instance.k3s_node.id
}

output "cell_summary" {
  description = "cell registry entry"
  value = {
    cell        = var.environment
    customer_id = var.customer_id
    tier        = var.tier
    region      = var.aws_region
    account_id  = data.aws_caller_identity.current.account_id
  }
}
