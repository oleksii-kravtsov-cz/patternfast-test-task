variable "aws_region" {
  type        = string
  default     = "eu-central-1"
  description = "aws region, EU for regulated"
}

variable "environment" {
  type        = string
  default     = "cell-01"
  description = "cell name, used as resource prefix"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{1,30}[a-z0-9])$", var.environment))
    error_message = "environment: 3-32 chars of [a-z0-9-]"
  }
}

variable "customer_id" {
  type        = string
  default     = "acme-042"
  description = "customer id"
}

variable "tier" {
  type        = string
  default     = "enterprise"
  description = "standard, enterprise or regulated"

  validation {
    condition     = contains(["standard", "enterprise", "regulated"], var.tier)
    error_message = "tier: standard, enterprise or regulated"
  }
}

variable "az_count" {
  type        = number
  default     = 2
  description = "azs to span, 2 or 3"

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count: 2 or 3"
  }
}

variable "vpc_cidr" {
  type        = string
  default     = "10.100.0.0/16"
  description = "vpc cidr, /16, must not overlap another cell"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) == 16
    error_message = "vpc_cidr: must be a valid /16"
  }
}

variable "db_username" {
  type        = string
  default     = "billing_admin"
  description = "rds master user, break-glass only"
}

variable "db_app_username" {
  type        = string
  default     = "billing_app"
  description = "db user the app connects as, iam auth"
}

variable "trusted_admin_cidrs" {
  type        = list(string)
  default     = ["10.200.0.0/16"]
  description = "cidrs allowed to reach the k8s api"

  validation {
    condition = alltrue([
      for cidr in var.trusted_admin_cidrs : tonumber(split("/", cidr)[1]) >= 16
    ])
    error_message = "trusted_admin_cidrs: /16 or narrower"
  }

  validation {
    condition     = length(var.trusted_admin_cidrs) > 0
    error_message = "trusted_admin_cidrs: at least one required"
  }
}

variable "github_repository" {
  type        = string
  default     = "acme-platform/billing-service"
  description = "owner/repo for the ci roles"
}

variable "github_deploy_environment" {
  type        = string
  default     = "cell-01"
  description = "github environment for the deploy role"
}

variable "create_github_oidc_provider" {
  type        = bool
  default     = true
  description = "create the oidc provider, false if one exists"
}

variable "github_oidc_thumbprints" {
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
  description = "github oidc thumbprints"
}

variable "db_instance_class" {
  type        = string
  default     = "db.t4g.medium"
  description = "rds instance class"
}

variable "performance_insights_enabled" {
  type        = bool
  default     = true
  description = "performance insights, false on micro classes"
}

variable "external_egress_cidrs" {
  type        = list(string)
  default     = []
  description = "external cidrs reachable on 443"

  validation {
    condition = alltrue([
      for cidr in var.external_egress_cidrs : tonumber(split("/", cidr)[1]) >= 16
    ])
    error_message = "external_egress_cidrs: /16 or narrower"
  }
}

variable "github_default_branch" {
  type        = string
  default     = "main"
  description = "branch for the build role"
}

variable "db_allocated_storage" {
  type        = number
  default     = 20
  description = "rds storage, gib"

  validation {
    condition     = var.db_allocated_storage >= 20 && var.db_allocated_storage <= 65536
    error_message = "db_allocated_storage: 20-65536"
  }
}

variable "db_backup_retention_days" {
  type        = number
  default     = 14
  description = "backup retention days"

  validation {
    condition     = var.db_backup_retention_days >= 7
    error_message = "db_backup_retention_days: min 7"
  }
}

variable "log_retention_days" {
  type        = number
  default     = 400
  description = "log retention days"

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days: not a value cloudwatch accepts"
  }

  validation {
    condition     = var.log_retention_days >= 400
    error_message = "log_retention_days: min 400"
  }
}

variable "node_instance_type" {
  type        = string
  default     = "t3.medium"
  description = "node instance type"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "extra tags"
}
