#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly SCRIPT_NAME REPO_ROOT RUN_ID

CUSTOMER_ID="${CUSTOMER_ID:-}"
AWS_REGION="${AWS_REGION:-}"
TIER="${TIER:-}"
CELL_NAME="${CELL_NAME:-}"
IMAGE_DIGEST="${IMAGE_DIGEST:-}"
K8S_NAMESPACE="${K8S_NAMESPACE:-billing}"
VPC_CIDR="${VPC_CIDR:-}"
BACKUP_RETENTION_DAYS=""

readonly BACKUP_RETENTION_STANDARD=7
readonly BACKUP_RETENTION_ENTERPRISE=14
readonly BACKUP_RETENTION_REGULATED=35
DRY_RUN=false
ASSUME_YES=false
LOG_DIR="${PROVISION_LOG_DIR:-${REPO_ROOT}/logs}"
LOG_FILE=""
EXIT_CODE=0
RUN_STARTED=false

readonly VALID_TIERS=("standard" "enterprise" "regulated")
readonly VALID_TIERS_DISPLAY="standard, enterprise, regulated"
readonly REQUIRED_BINARIES=("aws" "terraform" "helm" "kubectl" "jq" "curl")

usage() {
  cat <<USAGE
usage: ${SCRIPT_NAME} -c ID -r REGION -t TIER --vpc-cidr CIDR [-d DIGEST] [opts]

  -c ID          customer id
  -r REGION      aws region
  -t TIER        ${VALID_TIERS_DISPLAY}
  --vpc-cidr     /16 for this cell
  -d DIGEST      sha256:... image, required unless --dry-run
  --cell-name    default cell-<customer-id>
  --namespace    default billing
  -n, --dry-run  plan only
  -y, --yes      no prompt
  --log-dir DIR  default ${REPO_ROOT}/logs
  -h, --help

env: CUSTOMER_ID AWS_REGION TIER CELL_NAME IMAGE_DIGEST K8S_NAMESPACE
USAGE
}

log() {
  local level="$1"; shift
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [${RUN_ID}] ${level} $*"
  printf '%s\n' "$line" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}

log_info()  { log "INFO " "$@"; }
log_warn()  { log "WARN " "$@"; }
log_error() { log "ERROR" "$@"; }
log_audit() { log "AUDIT" "$@"; }

die() {
  log_error "$*"
  exit 1
}

run_step_always() {
  local description="$1"; shift
  log_audit "step-start ${description}"
  local rc=0
  "$@" >>"$LOG_FILE" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    log_audit "step-ok ${description}"
    return 0
  fi
  log_audit "step-failed rc=${rc} ${description}"
  return "$rc"
}

run_step() {
  local description="$1"; shift
  log_audit "step-start ${description}"
  if [[ "$DRY_RUN" == true ]]; then
    local rendered
    rendered="$(IFS=' '; printf '%s' "$*")"
    log_info "would run: ${rendered}"
    log_audit "step-skipped ${description}"
    return 0
  fi
  local rc=0
  "$@" >>"$LOG_FILE" 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    log_audit "step-ok ${description}"
    return 0
  fi
  log_audit "step-failed rc=${rc} ${description}"
  return "$rc"
}

on_exit() {
  EXIT_CODE=$?
  if [[ "${RUN_STARTED:-false}" != true ]]; then
    exit "$EXIT_CODE"
  fi
  if [[ $EXIT_CODE -eq 0 ]]; then
    log_audit "run-complete status=success"
  else
    log_audit "run-complete status=failed rc=${EXIT_CODE}"
  fi
  if [[ -n "${KUBECONFIG_FILE:-}" ]]; then
    rm -f "$KUBECONFIG_FILE"
  fi
  if [[ -n "${KUBECONFIG_DIR:-}" ]]; then
    rmdir "$KUBECONFIG_DIR" 2>/dev/null || true
  fi
  if [[ -n "$LOG_FILE" ]]; then
    printf 'Audit log: %s\n' "$LOG_FILE" >&2
  fi
  exit "$EXIT_CODE"
}
trap on_exit EXIT

need_value() {
  [[ $# -ge 2 ]] || { usage; die "$1 needs a value"; }
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--customer-id)  need_value "$@"; CUSTOMER_ID="$2";   shift 2 ;;
      -r|--aws-region)   need_value "$@"; AWS_REGION="$2";    shift 2 ;;
      -t|--tier)         need_value "$@"; TIER="$2";          shift 2 ;;
      -d|--image-digest) need_value "$@"; IMAGE_DIGEST="$2";  shift 2 ;;
      --cell-name)       need_value "$@"; CELL_NAME="$2";     shift 2 ;;
      --namespace)       need_value "$@"; K8S_NAMESPACE="$2"; shift 2 ;;
      --vpc-cidr)        need_value "$@"; VPC_CIDR="$2";      shift 2 ;;
      --log-dir)         need_value "$@"; LOG_DIR="$2";       shift 2 ;;
      -n|--dry-run)      DRY_RUN=true;    shift ;;
      -y|--yes)          ASSUME_YES=true; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) usage; die "unknown argument: $1" ;;
    esac
  done
}

validate_params() {
  [[ -n "$CUSTOMER_ID" ]] || { usage; die "missing --customer-id"; }
  [[ -n "$AWS_REGION" ]]  || { usage; die "missing --aws-region"; }
  [[ -n "$TIER" ]]        || { usage; die "missing --tier"; }

  [[ "$CUSTOMER_ID" =~ ^[a-z0-9]([a-z0-9-]{1,30}[a-z0-9])$ ]] \
    || die "bad --customer-id '${CUSTOMER_ID}': 3-32 chars, [a-z0-9-], no leading or trailing hyphen"

  [[ "$AWS_REGION" =~ ^[a-z]{2}(-[a-z]+){1,2}-[0-9]$ ]] \
    || die "bad --aws-region '${AWS_REGION}'"

  local valid=false
  local t
  for t in "${VALID_TIERS[@]}"; do
    [[ "$TIER" == "$t" ]] && valid=true
  done
  [[ "$valid" == true ]] || die "bad --tier '${TIER}': expected ${VALID_TIERS_DISPLAY}"

  if [[ "$TIER" == "regulated" && ! "$AWS_REGION" =~ ^eu- ]]; then
    die "regulated tier needs an EU region, got '${AWS_REGION}'"
  fi

  if [[ "$DRY_RUN" != true ]]; then
    [[ -n "$IMAGE_DIGEST" ]] \
      || die "missing --image-digest"
    [[ "$IMAGE_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] \
      || die "bad --image-digest '${IMAGE_DIGEST}': expected sha256:<64 hex>"
  fi

  [[ "$K8S_NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    || die "bad --namespace '${K8S_NAMESPACE}'"

  if [[ -n "$CELL_NAME" ]]; then
    [[ "$CELL_NAME" =~ ^[a-z0-9]([a-z0-9-]{1,30}[a-z0-9])$ ]] \
      || die "bad --cell-name '${CELL_NAME}': 3-32 chars, [a-z0-9-], no leading or trailing hyphen"
  fi

  [[ -n "$VPC_CIDR" ]] \
    || die "missing --vpc-cidr"
  [[ "$VPC_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/16$ ]] \
    || die "bad --vpc-cidr '${VPC_CIDR}': must be a /16"

  case "$TIER" in
    standard)   BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_STANDARD" ;;
    enterprise) BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_ENTERPRISE" ;;
    regulated)  BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_REGULATED" ;;
  esac
}

check_prerequisites() {
  local missing=""
  local binary
  for binary in "${REQUIRED_BINARIES[@]}"; do
    command -v "$binary" >/dev/null 2>&1 || missing="${missing}${missing:+ }${binary}"
  done
  if [[ -n "$missing" ]]; then
    die "missing: ${missing}"
  fi

  local identity
  if ! identity="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
    die "no AWS credentials"
  fi

  local account arn
  account="$(printf '%s' "$identity" | jq -r '.Account')"
  arn="$(printf '%s' "$identity" | jq -r '.Arn')"
  log_audit "caller account=${account} arn=${arn} host=$(hostname) user=${USER:-unknown}"
}

confirm() {
  [[ "$ASSUME_YES" == true || "$DRY_RUN" == true ]] && return 0
  printf 'Provision cell %s for customer %s (%s tier) in %s? [y/N] ' \
    "$CELL_NAME" "$CUSTOMER_ID" "$TIER" "$AWS_REGION" >&2
  local reply
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || die "aborted"
}

terraform_apply() {
  local tf_dir="${REPO_ROOT}/terraform"

  run_step_always "terraform init (cell ${CELL_NAME})" \
    terraform -chdir="$tf_dir" init -input=false -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=cells/${CELL_NAME}/terraform.tfstate" \
    -backend-config="region=${AWS_REGION}" \
    -backend-config="dynamodb_table=${STATE_LOCK_TABLE}"

  run_step_always "terraform plan (cell ${CELL_NAME})" \
    terraform -chdir="$tf_dir" plan -input=false -lock-timeout=5m -out="${CELL_NAME}.tfplan" \
    -var="environment=${CELL_NAME}" \
    -var="customer_id=${CUSTOMER_ID}" \
    -var="tier=${TIER}" \
    -var="aws_region=${AWS_REGION}" \
    -var="vpc_cidr=${VPC_CIDR}" \
    -var="db_backup_retention_days=${BACKUP_RETENTION_DAYS}" \
    -var="github_deploy_environment=${CELL_NAME}"

  if [[ "$DRY_RUN" == true ]]; then
    log_info "dry-run: nothing changed"
    rm -f "${tf_dir}/${CELL_NAME}.tfplan"
    return 0
  fi

  local apply_rc=0
  run_step "terraform apply (cell ${CELL_NAME})" \
    terraform -chdir="$tf_dir" apply -input=false -lock-timeout=5m -auto-approve "${CELL_NAME}.tfplan" \
    || apply_rc=$?
  rm -f "${tf_dir}/${CELL_NAME}.tfplan"
  [[ $apply_rc -eq 0 ]] || return "$apply_rc"
}

read_terraform_outputs() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "dry-run: skipping output collection"
    return 0
  fi
  local tf_dir="${REPO_ROOT}/terraform"
  local outputs
  outputs="$(terraform -chdir="$tf_dir" output -json)"

  APP_SECRET_ARN="$(printf '%s' "$outputs" | jq -r '.app_secret_arn.value')"
  WORKLOAD_ROLE_ARN="$(printf '%s' "$outputs" | jq -r '.billing_service_role_arn.value')"
  ECR_REPOSITORY_URL="$(printf '%s' "$outputs" | jq -r '.ecr_repository_url.value')"
  NODE_INSTANCE_ID="$(printf '%s' "$outputs" | jq -r '.node_instance_id.value')"
  KUBECONFIG_SECRET_ARN="$(printf '%s' "$outputs" | jq -r '.kubeconfig_secret_arn.value')"

  local name value
  for name in APP_SECRET_ARN WORKLOAD_ROLE_ARN ECR_REPOSITORY_URL NODE_INSTANCE_ID DB_SECRET_ARN KUBECONFIG_SECRET_ARN; do
    value="${!name:-}"
    if [[ -z "$value" || "$value" == "null" ]]; then
      die "terraform output ${name} is empty"
    fi
  done

  log_audit "outputs secret=${APP_SECRET_ARN} role=${WORKLOAD_ROLE_ARN} ecr=${ECR_REPOSITORY_URL} node=${NODE_INSTANCE_ID}"
}

fetch_kubeconfig() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "dry-run: skipping kubeconfig fetch"
    return 0
  fi

  local kubeconfig_dir kubeconfig_file
  kubeconfig_dir="$(mktemp -d)"
  chmod 700 "$kubeconfig_dir"
  KUBECONFIG_DIR="$kubeconfig_dir"
  kubeconfig_file="${kubeconfig_dir}/kubeconfig-${CELL_NAME}"
  local rc=0
  (
    umask 077
    aws secretsmanager get-secret-value \
      --secret-id "$KUBECONFIG_SECRET_ARN" \
      --region "$AWS_REGION" \
      --query SecretString --output text > "$kubeconfig_file" 2>>"$LOG_FILE"
  ) || rc=$?

  if [[ $rc -ne 0 || ! -s "$kubeconfig_file" ]]; then
    rm -f "$kubeconfig_file"
    die "could not fetch kubeconfig for ${CELL_NAME}"
  fi

  export KUBECONFIG="$kubeconfig_file"
  KUBECONFIG_FILE="$kubeconfig_file"
  log_audit "kubeconfig fetched"
}

seed_secrets() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "dry-run: skipping secret seeding"
    return 0
  fi

  local existing
  if existing="$(aws secretsmanager get-secret-value \
      --secret-id "$APP_SECRET_ARN" \
      --region "$AWS_REGION" \
      --query SecretString --output text 2>/dev/null)" && [[ -n "$existing" && "$existing" != "None" ]]; then
    unset existing
    log_info "app secret already set, leaving it"
    log_audit "secret-seed skipped arn=${APP_SECRET_ARN}"
    return 0
  fi

  local jwt_secret stripe_key
  printf 'JWT signing key for %s (input hidden): ' "$CELL_NAME" >&2
  read -rs jwt_secret; printf '\n' >&2
  printf 'Payment provider key for %s (input hidden): ' "$CELL_NAME" >&2
  read -rs stripe_key; printf '\n' >&2

  [[ -n "$jwt_secret" && -n "$stripe_key" ]] || die "secret values are empty"

  local payload_file
  payload_file="$(mktemp)"
  chmod 600 "$payload_file"

  printf '%s\n%s\n' "$jwt_secret" "$stripe_key" \
    | jq -Rn '{"jwt-secret": (input), "stripe-key": (input)}' > "$payload_file"
  unset jwt_secret stripe_key

  local rc=0
  aws secretsmanager put-secret-value \
    --secret-id "$APP_SECRET_ARN" \
    --region "$AWS_REGION" \
    --secret-string "file://${payload_file}" >/dev/null 2>>"$LOG_FILE" || rc=$?

  : > "$payload_file"
  rm -f "$payload_file"

  if [[ $rc -eq 0 ]]; then
    log_audit "secret-seed ok arn=${APP_SECRET_ARN}"
  else
    die "seeding the app secret failed (rc=${rc})"
  fi
}

deploy_workload() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "dry-run: skipping helm release"
    return 0
  fi

  if ! kubectl get namespace "$K8S_NAMESPACE" >/dev/null 2>&1; then
    run_step "create namespace ${K8S_NAMESPACE}" \
      kubectl create namespace "$K8S_NAMESPACE"
  fi
  run_step "enforce restricted pod security on ${K8S_NAMESPACE}" \
    kubectl label namespace "$K8S_NAMESPACE" \
      pod-security.kubernetes.io/enforce=restricted \
      pod-security.kubernetes.io/audit=restricted \
      pod-security.kubernetes.io/warn=restricted --overwrite

  run_step "helm upgrade --install billing-service (${CELL_NAME})" \
    helm upgrade --install billing-service "${REPO_ROOT}/charts/billing-service" \
      --namespace "$K8S_NAMESPACE" \
      --values "${REPO_ROOT}/charts/billing-service/values.production.yaml" \
      --set-string "serviceAccount.roleArn=${WORKLOAD_ROLE_ARN}" \
      --set-string "externalSecrets.remoteSecretName=/acme/${CELL_NAME}/billing-service/app" \
      --set-string "image.repository=${ECR_REPOSITORY_URL}" \
      --set-string "image.digest=${IMAGE_DIGEST}" \
      --atomic --wait --timeout 5m
}

smoke_test() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "dry-run: skipping smoke test"
    return 0
  fi

  run_step "rollout status" \
    kubectl -n "$K8S_NAMESPACE" rollout status deploy/billing-service-billing-service --timeout=2m

  kubectl -n "$K8S_NAMESPACE" port-forward svc/billing-service-billing-service 18080:3000 \
    >>"$LOG_FILE" 2>&1 &
  local pf_pid=$!
  sleep 5

  local rc=0
  curl -fsS --max-time 10 http://127.0.0.1:18080/health >>"$LOG_FILE" 2>&1 || rc=$?
  kill "$pf_pid" 2>/dev/null || true

  if [[ $rc -eq 0 ]]; then
    log_audit "step-ok: health probe"
    log_info "smoke test ok"
  else
    log_audit "step-failed (rc=${rc}): health probe"
    die "smoke test failed"
  fi
}

register_cell() {
  if [[ "$DRY_RUN" == true ]]; then
    log_info "dry-run: skipping cell registry entry"
    return 0
  fi

  if run_step "register cell in ${CELL_REGISTRY_TABLE}" \
      aws dynamodb put-item \
        --region "$AWS_REGION" \
        --table-name "$CELL_REGISTRY_TABLE" \
        --item "$(jq -nc \
            --arg cell "$CELL_NAME" \
            --arg customer "$CUSTOMER_ID" \
            --arg tier "$TIER" \
            --arg region "$AWS_REGION" \
            --arg provisioned "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{cell_id:{S:$cell},customer_id:{S:$customer},tier:{S:$tier},region:{S:$region},provisioned_at:{S:$provisioned}}')"; then
    log_audit "registry ok cell=${CELL_NAME}"
  else
    log_warn "registry update failed, record ${CELL_NAME} by hand"
  fi
}

main() {
  parse_args "$@"

  mkdir -p "$LOG_DIR"
  local log_customer="${CUSTOMER_ID:-unspecified}"
  log_customer="$(printf '%s' "$log_customer" | tr -c 'a-zA-Z0-9._-' '_')"
  LOG_FILE="${LOG_DIR}/provision-${log_customer}-${RUN_ID}.log"
  ( umask 077 && : > "$LOG_FILE" )

  RUN_STARTED=true
  log_audit "run-start customer=${CUSTOMER_ID:-none} tier=${TIER:-none} region=${AWS_REGION:-none} dry_run=${DRY_RUN}"

  validate_params

  CELL_NAME="${CELL_NAME:-cell-${CUSTOMER_ID}}"
  STATE_BUCKET="${STATE_BUCKET:-acme-platform-tfstate-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo unknown)}"
  STATE_LOCK_TABLE="${STATE_LOCK_TABLE:-acme-platform-tfstate-lock}"
  CELL_REGISTRY_TABLE="${CELL_REGISTRY_TABLE:-acme-platform-cell-registry}"

  log_audit "params ok cell=${CELL_NAME} ns=${K8S_NAMESPACE} cidr=${VPC_CIDR} retention=${BACKUP_RETENTION_DAYS}"

  check_prerequisites
  confirm

  terraform_apply
  read_terraform_outputs
  seed_secrets
  fetch_kubeconfig
  deploy_workload
  smoke_test
  register_cell

  if [[ "$DRY_RUN" == true ]]; then
    log_info "dry-run done"
  else
    log_info "cell ${CELL_NAME} ready (${TIER}, ${AWS_REGION})"
    log_info "next: DNS, TLS, on-call routing"
  fi
}

main "$@"
