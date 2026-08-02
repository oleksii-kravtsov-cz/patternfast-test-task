output "state_bucket" {
  description = "Bucket to pass as -backend-config=\"bucket=...\"."
  value       = aws_s3_bucket.state.bucket
}

output "lock_table" {
  description = "Table to pass as -backend-config=\"dynamodb_table=...\"."
  value       = aws_dynamodb_table.lock.name
}

output "cell_registry_table" {
  description = "cell registry table"
  value       = aws_dynamodb_table.cell_registry.name
}

output "kms_key_arn" {
  description = "state kms key arn"
  value       = aws_kms_key.state.arn
}
