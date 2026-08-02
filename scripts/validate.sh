#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
CHART="${REPO_ROOT}/charts/billing-service"
RENDERED="$(mktemp -t rendered.XXXXXX.yaml)"
STRICT=false
PASS=0
FAIL=0
SKIP=0

[[ "${1:-}" == "--strict" ]] && STRICT=true

cleanup() { rm -f "$RENDERED"; }
trap cleanup EXIT

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
skip() {
  if [[ "$STRICT" == true ]]; then
    fail "$1 (missing)"
  else
    printf 'SKIP  %s (not installed)\n' "$1"
    SKIP=$((SKIP + 1))
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

echo "terraform"
if have terraform; then
  check "tf fmt"                terraform -chdir="${REPO_ROOT}/terraform" fmt -check -recursive
  terraform -chdir="${REPO_ROOT}/terraform" init -backend=false -input=false >/dev/null 2>&1
  check "tf validate cell"    terraform -chdir="${REPO_ROOT}/terraform" validate
  terraform -chdir="${REPO_ROOT}/terraform/bootstrap" init -backend=false -input=false >/dev/null 2>&1
  check "tf validate bootstrap" terraform -chdir="${REPO_ROOT}/terraform/bootstrap" validate
else
  skip "terraform"
fi

if have tflint; then
  check "tflint" tflint --chdir="${REPO_ROOT}/terraform"
else
  skip "tflint"
fi

if have checkov; then
  check "checkov" checkov -d "${REPO_ROOT}/terraform" --skip-path '.terraform' --compact --quiet
else
  skip "checkov"
fi

echo "helm"
if have helm; then
  check "helm lint" helm lint "$CHART"
  check "helm template default" helm template billing-service "$CHART"
  if helm template billing-service "$CHART" \
       --values "${CHART}/values.production.yaml" \
       --set image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000 \
       > "$RENDERED" 2>/dev/null; then
    pass "helm template prod"
  else
    fail "helm template prod"
  fi

  if helm template billing-service "$CHART" --set networkPolicy.allowedPodLabels=null >/dev/null 2>&1; then
    fail "chart rejects empty pod selector"
  else
    pass "chart rejects empty pod selector"
  fi

  if helm template billing-service "$CHART" --set image.tag=latest --set image.digest= >/dev/null 2>&1; then
    fail "chart rejects latest tag"
  else
    pass "chart rejects latest tag"
  fi

  if [[ ! -s "$RENDERED" ]]; then
    fail "prod render produced output"
  fi

  if [[ -s "$RENDERED" ]]; then
    if grep -Eiq '(sk_(test|live)_|super-secret|change-me|BEGIN [A-Z ]*PRIVATE KEY)' "$RENDERED"; then
      fail "no literal secrets"
    else
      pass "no literal secrets"
    fi
    if grep -q 'secretKeyRef' "$RENDERED"; then
      pass "secretKeyRef used"
    else
      fail "secretKeyRef used"
    fi

    if grep -qE 'DB_PASS|db-password|PGPASSWORD' "$RENDERED"; then
      fail "no db password in the pod"
    else
      pass "no db password in the pod"
    fi
    for required in 'runAsNonRoot: true' 'readOnlyRootFilesystem: true' 'allowPrivilegeEscalation: false' \
                    'livenessProbe:' 'readinessProbe:' 'kind: NetworkPolicy' 'kind: ServiceAccount'; do
      if grep -q "$required" "$RENDERED"; then
        pass "manifest has ${required}"
      else
        fail "manifest has ${required}"
      fi
    done
  fi
else
  skip "helm"
fi

if have kubeconform && [[ -s "$RENDERED" ]]; then
  check "kubeconform" kubeconform -strict -ignore-missing-schemas "$RENDERED"
else
  skip "kubeconform"
fi

echo "workflow and scripts"
if have actionlint; then
  check "actionlint" actionlint -color=false
else
  skip "actionlint"
fi

if have shellcheck; then
  check "shellcheck provision-cell" shellcheck "${REPO_ROOT}/scripts/provision-cell.sh"
  check "shellcheck validate"       shellcheck "${REPO_ROOT}/scripts/validate.sh"
else
  skip "shellcheck"
fi
check "bash -n provision-cell" bash -n "${REPO_ROOT}/scripts/provision-cell.sh"

echo "container and deps"
if have hadolint; then
  check "hadolint" hadolint "${REPO_ROOT}/Dockerfile"
else
  skip "hadolint"
fi

if have npm; then
  check "npm audit" npm --prefix "$REPO_ROOT" audit --audit-level=high
else
  skip "npm audit"
fi

if have trivy; then
  check "trivy terraform" trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL \
    --skip-dirs '**/.terraform' "${REPO_ROOT}/terraform"
  check "trivy dockerfile" trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL "${REPO_ROOT}/Dockerfile"
  if [[ -s "$RENDERED" ]]; then
    check "trivy manifests" trivy config --quiet --exit-code 1 --severity HIGH,CRITICAL "$RENDERED"
  fi
else
  skip "trivy"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]]
