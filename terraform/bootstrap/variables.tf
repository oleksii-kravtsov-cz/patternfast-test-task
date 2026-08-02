variable "aws_region" {
  type        = string
  default     = "eu-central-1"
  description = "aws region"
}

variable "state_bucket_prefix" {
  type        = string
  default     = "acme-platform-tfstate"
  description = "state bucket prefix, account id appended"
}

variable "lock_table_name" {
  type        = string
  default     = "acme-platform-tfstate-lock"
  description = "state lock table"
}

variable "cell_registry_table_name" {
  type        = string
  default     = "acme-platform-cell-registry"
  description = "cell registry table"
}
