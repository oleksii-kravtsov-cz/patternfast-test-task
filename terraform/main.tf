provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  name = var.environment

  common_tags = merge(
    {
      Environment = var.environment
      CustomerId  = var.customer_id
      Tier        = var.tier
      ManagedBy   = "terraform"
      Component   = "billing-platform-cell"
    },
    var.tags
  )

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  endpoint_prefixes_without_resource_account = ["ssmmessages", "ec2messages", "sts"]

  endpoint_action_prefixes = {
    "ecr.api"        = "ecr"
    "ecr.dkr"        = "ecr"
    "ssm"            = "ssm"
    "ssmmessages"    = "ssmmessages"
    "ec2messages"    = "ec2messages"
    "secretsmanager" = "secretsmanager"
    "kms"            = "kms"
    "logs"           = "logs"
    "sts"            = "sts"
    "s3"             = "s3"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-default-deny-all" }
}

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "private_app" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-private-app-${local.azs[count.index]}", Tier = "private-app" }
}

resource "aws_subnet" "private_data" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 20)
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-private-data-${local.azs[count.index]}", Tier = "private-data" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${local.name}-nat" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = "${local.name}-nat" }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name}-private-app" }
}

resource "aws_route_table_association" "private_app" {
  count = length(aws_subnet.private_app)

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table" "private_data" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name}-private-data" }
}

resource "aws_route_table_association" "private_data" {
  count = length(aws_subnet.private_data)

  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private_data.id
}

data "aws_iam_policy_document" "endpoint_same_account" {
  # checkov:skip=CKV_AWS_49:A VPC endpoint policy has no identity principal to name; access is constrained by the aws:PrincipalAccount condition below.
  # checkov:skip=CKV_AWS_1:Same — the wildcard principal is structural to endpoint policies.
  # checkov:skip=CKV2_AWS_40:Actions are scoped to the single service this endpoint fronts; a per-action list would break as AWS adds API actions.
  for_each = local.endpoint_action_prefixes

  statement {
    sid       = "SameAccountOnly"
    effect    = "Allow"
    actions   = ["${each.value}:*"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    dynamic "condition" {
      for_each = contains(local.endpoint_prefixes_without_resource_account, each.value) ? [] : [1]

      content {
        test     = "StringEquals"
        variable = "aws:ResourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }

  dynamic "statement" {
    for_each = each.value == "ecr" ? [1] : []

    content {
      sid       = "EcrAuthorizationTokenIsAccountLevel"
      effect    = "Allow"
      actions   = ["ecr:GetAuthorizationToken"]
      resources = ["*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_app.id, aws_route_table.private_data.id]
  policy            = data.aws_iam_policy_document.endpoint_same_account["s3"].json

  tags = { Name = "${local.name}-s3" }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name}-vpc-endpoints"
  description = "HTTPS from the cell VPC to interface endpoints"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-vpc-endpoints" }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "HTTPS from within the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset([
    "ecr.api",
    "ecr.dkr",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "secretsmanager",
    "kms",
    "logs",
    "sts",
  ])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private_app[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  policy              = data.aws_iam_policy_document.endpoint_same_account[each.value].json

  tags = { Name = "${local.name}-${each.value}" }
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${local.name}/flow-logs"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    sid = "WriteToTheFlowLogGroup"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }

  statement {
    sid       = "ListLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "${local.name}-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
}

data "aws_iam_policy_document" "kms_data" {
  # checkov:skip=CKV_AWS_109:Resource "*" inside a KMS key policy means "this key only" — it cannot be narrowed further.
  # checkov:skip=CKV_AWS_111:Same. Key administration is scoped to the account root principal by design.
  # checkov:skip=CKV_AWS_356:Same.
  statement {
    sid       = "AccountRoot"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid = "AllowAwsServices"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = ["*"]

    principals {
      type = "Service"
      identifiers = [
        "rds.amazonaws.com",
        "s3.amazonaws.com",
        "secretsmanager.amazonaws.com",
        "ec2.amazonaws.com",
        "ecr.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "rds.${var.aws_region}.amazonaws.com",
        "s3.${var.aws_region}.amazonaws.com",
        "secretsmanager.${var.aws_region}.amazonaws.com",
        "ec2.${var.aws_region}.amazonaws.com",
        "ecr.${var.aws_region}.amazonaws.com",
      ]
    }
  }
}

resource "aws_kms_key" "data" {
  description             = "${local.name} data encryption key (RDS, S3, Secrets Manager, EBS)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms_data.json

  tags = { Name = "${local.name}-data" }
}

resource "aws_kms_alias" "data" {
  name          = "alias/${local.name}-data"
  target_key_id = aws_kms_key.data.key_id
}

data "aws_iam_policy_document" "kms_logs" {
  # checkov:skip=CKV_AWS_109:Resource "*" inside a KMS key policy means "this key only".
  # checkov:skip=CKV_AWS_111:Same.
  # checkov:skip=CKV_AWS_356:Same.
  statement {
    sid       = "AccountRoot"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "${local.name} log encryption key"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms_logs.json

  tags = { Name = "${local.name}-logs" }
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}

resource "aws_security_group" "k3s_node" {
  name        = "${local.name}-k3s-node"
  description = "Kubernetes node: API from trusted admin ranges only, no SSH"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-k3s-node" }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_api" {
  count = length(var.trusted_admin_cidrs)

  security_group_id = aws_security_group.k3s_node.id
  description       = "Kubernetes API from the VPN / Zero Trust range"
  cidr_ipv4         = var.trusted_admin_cidrs[count.index]
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_https_internal" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "HTTPS to VPC interface endpoints (ECR, SSM, Secrets Manager, KMS, Logs)"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_external_https" {
  count = length(var.external_egress_cidrs)

  security_group_id = aws_security_group.k3s_node.id
  description       = "HTTPS to a declared external dependency"
  cidr_ipv4         = var.external_egress_cidrs[count.index]
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_s3_gateway" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "HTTPS to S3 through the gateway endpoint"
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_dns_udp" {
  security_group_id = aws_security_group.k3s_node.id
  description       = "DNS"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 53
  to_port           = 53
  ip_protocol       = "udp"
}

resource "aws_vpc_security_group_egress_rule" "k3s_postgres" {
  security_group_id            = aws_security_group.k3s_node.id
  description                  = "PostgreSQL to the cell database"
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "PostgreSQL from the cell workload nodes only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-rds" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from workload nodes"
  referenced_security_group_id = aws_security_group.k3s_node.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints

  tags = { Name = "${local.name}-github-oidc" }
}

locals {
  github_oidc_provider_arn = (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
  )
}

data "aws_iam_policy_document" "github_build_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_default_branch}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = ["${var.github_repository}/.github/workflows/deploy.yml@refs/heads/${var.github_default_branch}"]
    }
  }
}

resource "aws_iam_role" "github_build" {
  name                 = "${local.name}-github-build"
  description          = "CI role for ${var.github_repository}: build and push images for ${local.name}"
  assume_role_policy   = data.aws_iam_policy_document.github_build_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_build" {
  # checkov:skip=CKV_AWS_111:ecr:GetAuthorizationToken has no resource-level ARN in IAM; every other action is pinned to this cell's repository.
  # checkov:skip=CKV_AWS_356:Same.
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPullThisRepositoryOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.billing_service.arn]
  }
}

resource "aws_iam_role_policy" "github_build" {
  name   = "${local.name}-github-build"
  role   = aws_iam_role.github_build.id
  policy = data.aws_iam_policy_document.github_build.json
}

data "aws_iam_policy_document" "github_deploy_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:${var.github_deploy_environment}"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values   = ["${var.github_repository}/.github/workflows/deploy.yml@refs/heads/${var.github_default_branch}"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${local.name}-github-deploy"
  description          = "Short-lived CI/CD role for ${var.github_repository} deploying ${local.name}"
  assume_role_policy   = data.aws_iam_policy_document.github_deploy_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  # checkov:skip=CKV_AWS_111:ssm:GetConnectionStatus has no resource-level ARN in IAM; every other action is pinned to this cell's instance, secret or key.
  # checkov:skip=CKV_AWS_356:Same — the "*" statements are read-only APIs that IAM cannot scope.

  statement {
    sid     = "SsmPortForwardToThisCellOnly"
    actions = ["ssm:StartSession"]
    resources = [
      aws_instance.k3s_node.arn,
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession",
    ]

    condition {
      test     = "Bool"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  statement {
    sid       = "SsmSessionStatus"
    actions   = ["ssm:GetConnectionStatus"]
    resources = ["*"]
  }

  statement {
    sid     = "SsmOwnSessionsOnly"
    actions = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = [
      "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:session/gha-deploy-*",
    ]
  }

  statement {
    sid       = "ReadClusterCredentialForThisCellOnly"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.kubeconfig.arn]
  }

  statement {
    sid       = "DecryptClusterCredential"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "${local.name}-github-deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "k3s_node" {
  name               = "${local.name}-k3s-node"
  description        = "Instance role for the ${local.name} Kubernetes node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "k3s_node_ssm" {
  role       = aws_iam_role.k3s_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "k3s_node" {
  statement {
    sid       = "PullImagesFromCellRepository"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PullImageLayers"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.billing_service.arn]
  }
}

resource "aws_iam_role_policy" "k3s_node" {
  name   = "${local.name}-k3s-node"
  role   = aws_iam_role.k3s_node.id
  policy = data.aws_iam_policy_document.k3s_node.json
}

resource "aws_iam_instance_profile" "k3s_node" {
  name = "${local.name}-k3s-node"
  role = aws_iam_role.k3s_node.name
}

data "aws_iam_policy_document" "billing_service_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.k3s_node.arn]
    }
  }
}

data "aws_iam_policy_document" "billing_service" {
  statement {
    sid       = "ReadOwnSecretOnly"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.billing_service.arn]
  }

  statement {
    sid     = "ConnectToDatabaseWithIamAuth"
    actions = ["rds-db:connect"]
    resources = [
      "arn:${data.aws_partition.current.partition}:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.billing.resource_id}/${var.db_app_username}",
    ]
  }

  statement {
    sid       = "WriteOwnExportPrefixOnly"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.billing_exports.arn}/billing-service/*"]
  }

  statement {
    sid       = "ListOwnExportPrefixOnly"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.billing_exports.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["billing-service/*"]
    }
  }

  statement {
    sid       = "UseCellDataKeyViaOwnServicesOnly"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.data.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "s3.${var.aws_region}.amazonaws.com",
        "secretsmanager.${var.aws_region}.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role" "billing_service" {
  name               = "${local.name}-billing-service"
  description        = "Workload role for billing-service in ${local.name}"
  assume_role_policy = data.aws_iam_policy_document.billing_service_assume.json
}

resource "aws_iam_role_policy" "billing_service" {
  name   = "${local.name}-billing-service"
  role   = aws_iam_role.billing_service.id
  policy = data.aws_iam_policy_document.billing_service.json
}

resource "aws_secretsmanager_secret" "billing_service" {
  # checkov:skip=CKV2_AWS_57:Managed rotation applies to the database credential (handled by RDS). The JWT signing key and payment provider key rotate through the documented dual-key procedure in SECURITY.md, which requires application coordination a rotation Lambda cannot provide.
  name        = "/acme/${local.name}/billing-service/app"
  description = "Application secrets for billing-service in ${local.name} (JWT signing key, payment provider key)"
  kms_key_id  = aws_kms_key.data.arn

  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "kubeconfig" {
  # checkov:skip=CKV2_AWS_57:A kubeconfig is rotated by re-issuing cluster credentials, which is a cluster operation rather than a Secrets Manager rotation Lambda.
  name        = "/acme/${local.name}/platform/kubeconfig"
  description = "Kubeconfig for ${local.name}, consumed by the deploy pipeline over the SSM tunnel"
  kms_key_id  = aws_kms_key.data.arn

  recovery_window_in_days = 30
}

resource "aws_ecr_repository" "billing_service" {
  name                 = "${local.name}/billing-service"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.data.arn
  }

  tags = { Name = "${local.name}-billing-service" }
}

resource "aws_ecr_lifecycle_policy" "billing_service" {
  repository = aws_ecr_repository.billing_service.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 30 most recent images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 30
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db-subnet"
  subnet_ids = aws_subnet.private_data[*].id

  tags = { Name = "${local.name}-db-subnet" }
}

resource "aws_db_parameter_group" "billing" {
  name_prefix = "${local.name}-billing-pg16-"
  family      = "postgres16"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "billing" {
  identifier                          = "${local.name}-billing-db"
  iam_database_authentication_enabled = true
  engine                              = "postgres"
  engine_version                      = "16"
  instance_class                      = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 5
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.data.arn

  db_name                       = "billing"
  username                      = var.db_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.data.arn

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.billing.name
  publicly_accessible    = false
  multi_az               = true

  backup_retention_period   = var.db_backup_retention_days
  backup_window             = "01:00-02:00"
  maintenance_window        = "sun:02:30-sun:03:30"
  copy_tags_to_snapshot     = true
  delete_automated_backups  = false
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-billing-db-final-${random_id.bucket.hex}"

  auto_minor_version_upgrade = true

  performance_insights_enabled    = var.performance_insights_enabled
  performance_insights_kms_key_id = var.performance_insights_enabled ? aws_kms_key.data.arn : null

  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = { Name = "${local.name}-billing-db" }

  depends_on = [aws_cloudwatch_log_group.rds]
}

resource "aws_cloudwatch_log_group" "rds" {
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${local.name}-billing-db/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

data "aws_iam_policy_document" "rds_monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:rds:${var.aws_region}:${data.aws_caller_identity.current.account_id}:db:*"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${local.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "random_id" "bucket" {
  byte_length = 4
}

resource "aws_s3_bucket" "billing_exports" {
  # checkov:skip=CKV_AWS_144:Cross-region replication is a Regulated-tier control (EU-only target region) and is enabled per tier, not for every cell — see docs/architecture-proposal.md A5.
  # checkov:skip=CKV2_AWS_62:Event notifications are an application concern here; export delivery is driven by the service, not by bucket events.
  bucket = "${local.name}-billing-exports-${random_id.bucket.hex}"

  tags = { Name = "${local.name}-billing-exports" }
}

resource "aws_s3_bucket_public_access_block" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  rule {
    id     = "expire-exports"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id

  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "billing-exports/"

  depends_on = [aws_s3_bucket_policy.access_logs]
}

data "aws_iam_policy_document" "billing_exports" {
  statement {
    sid       = "DenyNonTlsRequests"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.billing_exports.arn, "${aws_s3_bucket.billing_exports.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyWrongEncryptionAlgorithm"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.billing_exports.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "billing_exports" {
  bucket = aws_s3_bucket.billing_exports.id
  policy = data.aws_iam_policy_document.billing_exports.json

  depends_on = [aws_s3_bucket_public_access_block.billing_exports]
}

resource "aws_s3_bucket" "access_logs" {
  # checkov:skip=CKV_AWS_145:S3 server access logging cannot deliver to an SSE-KMS bucket; SSE-S3 is the only option AWS supports for a log destination.
  # checkov:skip=CKV_AWS_144:Cross-region replication is a Regulated-tier control, not a per-cell default.
  # checkov:skip=CKV2_AWS_62:Event notifications add no control value for an access-log sink.
  # checkov:skip=CKV_AWS_18:This bucket is the access-log destination; logging it into itself would recurse.
  bucket = "${local.name}-access-logs-${random_id.bucket.hex}"

  tags = { Name = "${local.name}-access-logs" }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "access_logs" {
  statement {
    sid       = "AllowS3ServerAccessLogDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.billing_exports.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "DenyNonTlsRequests"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.access_logs.arn, "${aws_s3_bucket.access_logs.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs.json

  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "retain-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_instance" "k3s_node" {
  ami                    = data.aws_ssm_parameter.amazon_linux.value
  instance_type          = var.node_instance_type
  subnet_id              = aws_subnet.private_app[0].id
  vpc_security_group_ids = [aws_security_group.k3s_node.id]
  iam_instance_profile   = aws_iam_instance_profile.k3s_node.name

  associate_public_ip_address = false
  ebs_optimized               = true
  monitoring                  = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    encrypted   = true
    kms_key_id  = aws_kms_key.data.arn
    volume_type = "gp3"
    volume_size = 50
  }

  tags = { Name = "${local.name}-k3s-node" }

  lifecycle {
    ignore_changes = [ami]
  }
}

data "aws_ssm_parameter" "amazon_linux" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
