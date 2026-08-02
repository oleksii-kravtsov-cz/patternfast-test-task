# Security — billing-service, cell-01

Covers `terraform/`, `charts/billing-service/`, `.github/workflows/deploy.yml`, `scripts/`.
Report suspected vulnerabilities to `security@platform.example.com`, not a public issue.

## SOC 2 controls

### CC6.1 — Logical access

| Control | Where |
|---|---|
| No IAM users, no `AdministratorAccess`; humans use Identity Center with MFA and ≤1 h sessions | `terraform/main.tf` |
| CI uses GitHub OIDC, no static keys. Build role pinned to repo, branch and workflow; deploy role to the approval-gated environment | `github_build_assume`, `github_deploy_assume` |
| Build role pushes to one ECR repo; deploy role port-forwards to one instance and reads one secret | `github_build`, `github_deploy` |
| K8s API reachable only from the VPN range, validation rejects prefixes wider than /16, no SSH | `variables.tf`, security groups |
| Database takes traffic from the node security group only, not public, `rds.force_ssl` on | `aws_db_instance.billing` |
| **No database credential reaches the pod** — IAM token as `billing_app`; the role holds neither the master secret nor `rds-db:connect` for the master user | `billing_service` role, `externalsecret.yaml` |
| In-cluster traffic default-deny, API gateway only | `networkpolicy.yaml` |

Evidence: plan output with zero `aws_iam_user`, OIDC trust policy, CloudTrail `AssumeRoleWithWebIdentity`, security-group inventory, quarterly access reviews.

### CC7.2 — Monitoring

| Control | Where |
|---|---|
| VPC flow logs, KMS-encrypted, 400-day retention | `aws_flow_log.main` |
| RDS enhanced monitoring, Performance Insights, Postgres log export | `aws_db_instance.billing` |
| S3 access logging to a dedicated bucket | `aws_s3_bucket_logging.billing_exports` |
| ECR enhanced scanning re-scans pushed images; Trivy fails CI on HIGH or CRITICAL | `terraform/bootstrap`, `deploy.yml` |
| Every provisioning run records caller identity, parameters and step results | `scripts/provision-cell.sh` |

Evidence: flow and RDS logs, scan history, pipeline runs blocked by the gate, provisioning audit logs.

### CC8.1 — Change management

| Control | Where |
|---|---|
| Infrastructure is code; state remote, encrypted, versioned, locked | `versions.tf`, `terraform/bootstrap/` |
| Verify job gates every change: `npm ci`, `npm audit`, helm lint and template, terraform fmt and validate, Trivy | `deploy.yml` |
| Deploy runs in the `cell-01` environment; the required-reviewer rule is a repository setting (see README) | `deploy.yml` |
| Artifact deployed is the artifact scanned: built, scanned, pushed, deployed by digest; chart refuses `latest` or a malformed digest | `deploy.yml`, `_helpers.tpl` |
| Actions pinned to major tags tracked by Dependabot; ECR tags immutable | `deploy.yml`, `aws_ecr_repository` |
| `--atomic` rolls back a failed release; summary records digest, run, actor | `deploy.yml` |
| Build fails if a rendered manifest carries a literal secret or drops `secretKeyRef` | `deploy.yml` |

Evidence: PR approvals, workflow logs, digests correlated to commits, `helm history`.

## Risks

| # | Risk | Likelihood / impact | Mitigation | Residual |
|---|---|---|---|---|
| 1 | Secrets in config — the starter shipped a DB password, JWT key and payment key in `values.yaml` | was certain / critical | Secrets in Secrets Manager, projected by ESO, read via `secretKeyRef`; Terraform creates containers not values; CI fails on literal secrets | Starter placeholders remain in git history; real ones would be rotated, not just deleted |
| 2 | Network exposure — K8s API and SSH open to the internet, database open to the VPC | was certain / critical | API limited to the VPN range, SSH removed for SSM, database limited to the node security group, nodes private, default SG emptied, data subnets without NAT | External egress is CIDR-based; hostname filtering belongs to Network Firewall, outside this module |
| 3 | Unencrypted data at rest — no `storage_encrypted`, no bucket encryption or public access block | was certain / high | Customer-managed KMS on RDS, S3, EBS, Secrets Manager; public access block, versioning, TLS-only and encryption-required policies | An operator with `kms:Decrypt` can still read data; use is logged |
| 4 | Supply-chain compromise — the pipeline legitimately deploys to production | low–medium / critical | OIDC pinned to repo, branch, environment and workflow; audit and Trivy gates; scan before push; deploy by digest; immutable tags; SBOM; approval | A maintainer approving their own PR is a single point of trust; branch protection requires a second reviewer |
| 5 | Container escape or lateral movement | low / high | Non-root, read-only rootfs, no privilege escalation, capabilities dropped, seccomp; no token mounted; NetworkPolicy admits the gateway only; IRSA scoped to one secret and prefix; IMDSv2 hop limit 1 | A kernel escape still reaches the node; reduced by managed images and a minimal node role |

## Rotation runbook

Each rotation is an approved change with a ticket reference.

### Database master password — quarterly, or on suspicion

1. `aws secretsmanager rotate-secret --secret-id $(terraform -chdir=terraform output -raw rds_master_user_secret_arn)`
2. Wait for `AWSCURRENT` to move.
3. No workload action — the app uses an IAM token and never holds this credential. Only break-glass users are affected.
4. Verify: `/health` returns 200, and `kubectl -n billing exec deploy/billing-service-billing-service -- env | grep -c PASS` returns 0.
5. Rollback: the previous version stays as `AWSPREVIOUS`.

### JWT signing key — every 90 days, or on suspicion

Overlapping keys, so live sessions survive.

1. Generate outside the repo: `openssl rand -base64 48`.
2. Store as `jwt-secret-next` beside `jwt-secret`.
3. Deploy verifying with both, signing with the current key.
4. Promote `jwt-secret-next` to `jwt-secret`.
5. After one token TTL plus margin, drop the old key.
6. Verify no spike in 401s. Before step 5 rollback is config; after it, roll forward.

### Payment provider key — every 180 days, or on suspicion

1. Create a new restricted key at the provider; do not revoke the old one.
2. Store it under `stripe-key`.
3. Force a re-fetch and confirm the Secret changed before restarting — a restart alone keeps the old value until `refreshInterval` (1 h):
   ```
   kubectl -n billing annotate externalsecret billing-service-billing-service force-sync=$(date +%s) --overwrite
   kubectl -n billing get secret billing-service-secrets -o jsonpath='{.metadata.resourceVersion}'
   kubectl -n billing rollout restart deploy/billing-service-billing-service
   ```
4. Verify a live transaction and provider-side traffic.
5. Revoke the old key after 24 h clean.

### KMS keys — automatic annually

No action for routine rotation. On compromise: new key, restore RDS from a snapshot under it, copy S3 objects, update `kms_key_id`, apply, verify, schedule deletion of the old key with a 30-day window. For BYOK the customer supplies new material; confirm readability first.

### CI/CD roles — reviewed quarterly

Nothing static to rotate. Confirm `sub` and `job_workflow_ref` still pin the intended repository, branch, environment and workflow — a rename silently widens them — and drop permissions the pipeline no longer uses. On suspected leak, delete the role to kill live sessions, re-apply, and audit CloudTrail for calls with no matching workflow run.

### Break-glass — after every use

Assumption pages security and is recorded. Within one business day, review the session against its ticket and rotate anything it could have read. A rising rate is a finding.
