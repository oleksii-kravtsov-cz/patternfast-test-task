# billing-service — cell-01

Infrastructure, chart and pipeline for `billing-service` in the Enterprise cell `cell-01`.

- Part A — [`docs/architecture-proposal.md`](docs/architecture-proposal.md)
- Part B — the hardening in this repo
- Security posture, risks, rotation runbooks — [`SECURITY.md`](SECURITY.md)

All names are placeholders. Nothing here has been deployed.

## Layout

| Path | |
|---|---|
| `terraform/` | cell: VPC, security groups, IAM, KMS, RDS, S3, ECR, Secrets Manager, node |
| `terraform/bootstrap/` | state backend, lock table, cell registry, ECR scanning |
| `charts/billing-service/` | workload chart, `values.production.yaml` for cell-01 |
| `.github/workflows/deploy.yml` | verify → build and scan → approve → deploy |
| `scripts/provision-cell.sh` | provisions a cell, with audit logging |
| `scripts/validate.sh` | runs every static check |

## Setup

Bootstrap the backend once per account:

```bash
terraform -chdir=terraform/bootstrap init && terraform -chdir=terraform/bootstrap apply
```

Then the cell:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars

terraform -chdir=terraform init \
  -backend-config="bucket=acme-platform-tfstate-<account-id>" \
  -backend-config="key=cells/cell-01/terraform.tfstate" \
  -backend-config="region=eu-central-1" \
  -backend-config="dynamodb_table=acme-platform-tfstate-lock"

terraform -chdir=terraform apply
```

Or the whole cell in one step:

```bash
scripts/provision-cell.sh -c acme-042 -r eu-central-1 -t enterprise --vpc-cidr 10.101.0.0/16 --dry-run
scripts/provision-cell.sh -c acme-042 -r eu-central-1 -t enterprise --vpc-cidr 10.101.0.0/16 -d sha256:<digest>
```

Needs `aws`, `terraform`, `helm`, `kubectl`, `jq`, `curl`. `--dry-run` runs init and plan, then stops. Backup retention follows the tier: 7 / 14 / 35 days.

## CI/CD prerequisites

Set outside this repo:

- Repository variables from the Terraform outputs: `AWS_BUILD_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `WORKLOAD_ROLE_ARN`, `CELL_NODE_INSTANCE_ID`.
- A GitHub Environment per cell with a required reviewer — this is the approval gate.
- Branch protection on `main` requiring code owner review.
- External Secrets Operator, ingress controller and cert-manager in the cell, plus a namespaced `SecretStore` bound to the workload ServiceAccount.
- App secrets at `/acme/cell-01/billing-service/app` (`jwt-secret`, `stripe-key`). No DB password — the app uses an IAM auth token.
- Database user: `CREATE USER billing_app; GRANT rds_iam TO billing_app;`
- Kubeconfig at `/acme/cell-01/platform/kubeconfig`, written out of band.

## Checks

```bash
scripts/validate.sh
```

30 checks: terraform fmt and validate, tflint, checkov, helm lint and template, chart guard assertions, kubeconform, actionlint, shellcheck, hadolint, npm audit, trivy. Currently 30 passed, checkov 382/0/27, trivy 1 LOW on terraform and 3 LOW on rendered manifests.

Smoke test: `node src/health.js & curl http://localhost:3000/health`

## Known limitations

1. Nothing is deployed; everything is validated statically, so apply-time behaviour is unverified.
2. The node is a placeholder with no k3s. EKS, ElastiCache, Network Firewall, CloudTrail and GuardDuty are in the design, not this module.
3. ESO, ingress and cert-manager are assumed present.
4. The SSM tunnel to a private API server is untested against a live cluster.
5. The stub app has no graceful shutdown, and both probes use `/health`.
6. Egress FQDN filtering is deferred to Network Firewall; this module takes CIDRs only.
7. Cross-region replication and Object Lock are Regulated-tier controls, not enabled here.
8. Starter placeholder secrets remain in early git history; real ones would be rotated, not just removed.
9. IRSA is nominal on the placeholder: the role is assumed by the node role until an EKS OIDC provider exists.
10. The approval gate and branch protection are repository settings, not code.
11. The pipeline is cell-01 specific.
12. `npm audit` has no dependencies to audit; the gate is wired for a real tree.
13. One NAT gateway, not one per AZ.
14. The SSM condition uses `Bool` rather than AWS's usual `BoolIfExists`, so it fails closed. Confirm on first run.
15. `STRIPE_SECRET_KEY` is inherited from the starter's app contract; prose says "payment provider".

Do not commit secrets. Do not use real company or customer names.
