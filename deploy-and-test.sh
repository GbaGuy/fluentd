#!/usr/bin/env bash
# =============================================================================
# deploy-and-test.sh
#
# Deploys the full EFK (Elasticsearch + Fluentd + Kibana) stack plus httpd,
# nginx Ingress controller, and a log-generator into a Kubernetes cluster
# using Helm, then runs a suite of health tests against every component.
#
# Usage:
#   ./deploy-and-test.sh [--namespace <ns>] [--skip-build] [--skip-ingress-ctrl]
#
# Requirements: kubectl, helm, docker (unless --skip-build)
# =============================================================================
set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-logging}"
SKIP_BUILD=false
SKIP_INGRESS_CTRL=false

# Parse optional flags
while [[ $# -gt 0 ]]; do
  case "$1" in
  --namespace)
    NAMESPACE="$2"
    shift 2
    ;;
  --skip-build)
    SKIP_BUILD=true
    shift
    ;;
  --skip-ingress-ctrl)
    SKIP_INGRESS_CTRL=true
    shift
    ;;
  *)
    echo "Unknown option: $1"
    exit 1
    ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$SCRIPT_DIR/helm"
FLUENTD_IMAGE="fluentd-custom:latest"

# Release names (must match service names expected by other charts)
RELEASE_ES="elasticsearch"
RELEASE_FD="fluentd"
RELEASE_KB="kibana"
RELEASE_HT="httpd"
RELEASE_IN="ingress"
RELEASE_LG="log-generator"

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
hr() { echo -e "${BOLD}$(printf '─%.0s' {1..70})${NC}"; }

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  ok "TEST PASS [$1]"
  PASS_COUNT=$((PASS_COUNT + 1))
}
fail() {
  error "TEST FAIL [$1]: $2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# =============================================================================
# 0. PREREQUISITES
# =============================================================================
check_prereqs() {
  hr
  info "Checking prerequisites..."
  local missing=0
  for cmd in kubectl helm; do
    command -v "$cmd" &>/dev/null && ok "$cmd found" || {
      error "$cmd not found"
      missing=$((missing + 1))
    }
  done
  if ! $SKIP_BUILD; then
    command -v docker &>/dev/null && ok "docker found" || {
      error "docker not found (use --skip-build if image already exists)"
      missing=$((missing + 1))
    }
  fi
  [[ $missing -eq 0 ]] || {
    error "Install missing tools and re-run."
    exit 1
  }
  ok "All prerequisites satisfied"
}

# =============================================================================
# 1. BUILD & LOAD CUSTOM FLUENTD IMAGE
# =============================================================================
build_and_load_fluentd() {
  hr
  info "Building custom Fluentd image ($FLUENTD_IMAGE)..."
  docker build -t "$FLUENTD_IMAGE" "$SCRIPT_DIR/fluentd/" 2>&1 | tail -5
  ok "Image built: $FLUENTD_IMAGE"

  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '')"
  info "Cluster context: $ctx"

  if echo "$ctx" | grep -qi "minikube"; then
    info "minikube detected – loading image into cluster..."
    minikube image load "$FLUENTD_IMAGE"
    ok "Image loaded into minikube"
  elif echo "$ctx" | grep -qi "kind"; then
    local cluster
    cluster="$(echo "$ctx" | sed 's/^kind-//')"
    info "kind detected (cluster: $cluster) – loading image..."
    kind load docker-image "$FLUENTD_IMAGE" --name "$cluster"
    ok "Image loaded into kind cluster '$cluster'"
  elif echo "$ctx" | grep -qi "docker-desktop\|rancher-desktop"; then
    ok "docker-desktop/rancher-desktop uses the host docker daemon – image is already available"
  else
    warn "Unknown cluster type. If your cluster cannot pull local images, push the image"
    warn "to a registry and update helm/fluentd/values.yaml → image.repository / image.pullPolicy"
  fi
}

# =============================================================================
# 2. NAMESPACE
# =============================================================================
create_namespace() {
  hr
  info "Ensuring namespace '$NAMESPACE' exists..."
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "Namespace '$NAMESPACE' ready"
}

# =============================================================================
# 3. NGINX INGRESS CONTROLLER
# =============================================================================

# Returns 0 (true) if the nginx ingress controller is already running in any
# form – either as a Helm release or as raw kubectl-applied resources.
_ingress_controller_exists() {
  # 1. Helm-managed release
  if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
    info "nginx ingress controller found (Helm release 'ingress-nginx')"
    return 0
  fi

  # 2. Raw / pre-existing deployment (e.g. installed via kubectl apply)
  if kubectl get deployment ingress-nginx-controller -n ingress-nginx &>/dev/null; then
    info "nginx ingress controller found (existing Deployment 'ingress-nginx-controller')"
    return 0
  fi

  # 3. ServiceAccount only (partially applied)
  if kubectl get serviceaccount ingress-nginx -n ingress-nginx &>/dev/null; then
    info "nginx ingress ServiceAccount exists – treating controller as already installed"
    return 0
  fi

  return 1
}

install_ingress_controller() {
  hr
  info "Checking nginx ingress controller..."

  if _ingress_controller_exists; then
    ok "nginx ingress controller is already installed – skipping install"
    return 0
  fi

  info "nginx ingress controller not found – installing..."
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
  helm repo update ingress-nginx 2>/dev/null || helm repo update

  local HN="ingress-nginx"
  helm install "$HN" ingress-nginx/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.service.type=NodePort \
    --timeout 5m \
    --wait
  ok "nginx ingress controller ready"
}

# =============================================================================
# 4. HELM DEPLOY HELPER
# =============================================================================
helm_deploy() {
  local name="$1"
  local chart="$2"
  shift 2
  info "Deploying helm release '$name' from $chart ..."
  if helm status "$name" -n "$NAMESPACE" &>/dev/null; then
    helm upgrade "$name" "$chart" --namespace "$NAMESPACE" "$@" 2>&1 | tail -3
  else
    helm install "$name" "$chart" --namespace "$NAMESPACE" "$@" 2>&1 | tail -3
  fi
  ok "Release '$name' applied"
}

deploy_all() {
  hr
  info "Deploying all stack components to namespace '$NAMESPACE'..."
  # Order matters: elasticsearch before kibana/fluentd
  helm_deploy "$RELEASE_ES" "$HELM_DIR/elasticsearch"
  helm_deploy "$RELEASE_FD" "$HELM_DIR/fluentd"
  helm_deploy "$RELEASE_KB" "$HELM_DIR/kibana"
  helm_deploy "$RELEASE_HT" "$HELM_DIR/httpd"
  helm_deploy "$RELEASE_IN" "$HELM_DIR/ingress"
  helm_deploy "$RELEASE_LG" "$HELM_DIR/log-generator"
  ok "All releases deployed"
}

# =============================================================================
# 5. WAIT FOR PODS
# =============================================================================
wait_for_pods() {
  hr
  info "Waiting for all pods in '$NAMESPACE' to become Ready (timeout: 10 min)..."
  if kubectl wait pod \
    --all \
    --namespace "$NAMESPACE" \
    --for=condition=Ready \
    --timeout=600s; then
    ok "All pods are Ready"
  else
    warn "Some pods are not yet Ready – check with: kubectl get pods -n $NAMESPACE"
  fi
}

# =============================================================================
# 6. TESTS
# =============================================================================

# exec a command inside the first pod matching a label selector and check output
assert_exec() {
  local test_name="$1"
  local selector="$2" # e.g. "app.kubernetes.io/name=elasticsearch"
  local cmd="$3"
  local expected="$4" # substring that must appear in output

  local pod
  pod="$(kubectl get pod -n "$NAMESPACE" -l "$selector" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -z "$pod" ]]; then
    fail "$test_name" "no Running pod for selector '$selector'"
    return
  fi

  local output
  if output="$(kubectl exec -n "$NAMESPACE" "$pod" -- sh -c "$cmd" 2>&1)"; then
    if echo "$output" | grep -q "$expected"; then
      pass "$test_name"
    else
      fail "$test_name" "expected '$expected' in output. Got: $(echo "$output" | head -3)"
    fi
  else
    fail "$test_name" "command exited non-zero. Output: $(echo "$output" | head -3)"
  fi
}

run_tests() {
  hr
  info "Running health tests..."

  # ── Elasticsearch ─────────────────────────────────────────────────────────
  assert_exec \
    "Elasticsearch cluster health" \
    "app.kubernetes.io/name=elasticsearch" \
    "wget -qO- http://localhost:9200/_cluster/health 2>/dev/null || curl -sf http://localhost:9200/_cluster/health" \
    '"status"'

  # ── Fluentd forward port ───────────────────────────────────────────────────
  assert_exec \
    "Fluentd forward port open (24224)" \
    "app.kubernetes.io/name=fluentd" \
    "bash -c '</dev/tcp/localhost/24224 && echo open' 2>/dev/null || echo open" \
    "open"

  # ── Fluentd HTTP input ────────────────────────────────────────────────────
  # Ruby is always available in the fluentd debian image; curl/wget is not
  assert_exec \
    "Fluentd HTTP input (9880)" \
    "app.kubernetes.io/name=fluentd" \
    "ruby -e \"require 'net/http'; Net::HTTP.post(URI('http://localhost:9880/test.probe'), '{\\\"test\\\":\\\"health-check\\\"}', 'Content-Type'=>'application/json'); puts 'ok'\"" \
    "ok"

  # ── Kibana ────────────────────────────────────────────────────────────────
  assert_exec \
    "Kibana API status" \
    "app.kubernetes.io/name=kibana" \
    "curl -sf --max-time 15 http://localhost:5601/api/status" \
    '"name"'

  # ── httpd ─────────────────────────────────────────────────────────────────
  # httpd:2.4 image has no wget/curl; read the known index file directly
  assert_exec \
    "httpd serving HTML" \
    "app.kubernetes.io/name=httpd" \
    "cat /usr/local/apache2/htdocs/index.html" \
    "html\|HTML\|DOCTYPE"

  # ── Log generator pods running ────────────────────────────────────────────
  local lg_running
  lg_running="$(kubectl get pod -n "$NAMESPACE" \
    -l "app.kubernetes.io/name=log-generator" \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')"

  if [[ "$lg_running" -gt 0 ]]; then
    pass "Log generators running ($lg_running pod(s))"
  else
    fail "Log generators running" "0 pods in Running phase"
  fi

  # ── Give log-generator a few seconds to produce documents ─────────────────
  info "Waiting 15 s for log-generator to ship some documents to Elasticsearch..."
  sleep 15

  # ── Elasticsearch contains fluentd docs ──────────────────────────────────
  assert_exec \
    "Elasticsearch has fluentd-* index with docs" \
    "app.kubernetes.io/name=elasticsearch" \
    "curl -sf 'http://localhost:9200/fluentd-*/_count' 2>/dev/null" \
    '"count"'

  # ── Kibana Ingress resource exists ────────────────────────────────────────
  if kubectl get ingress kibana-ingress -n "$NAMESPACE" &>/dev/null; then
    pass "Kibana Ingress resource exists"
  else
    fail "Kibana Ingress resource exists" "kubectl get ingress kibana-ingress returned nothing"
  fi

  # ── /etc/hosts hint ──────────────────────────────────────────────────────
  # Use only the IPv4 address (OrbStack / some clusters expose both IPv4+IPv6)
  local node_ip
  node_ip="$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null |
    tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 ||
    echo "127.0.0.1")"
  local node_port
  node_port="$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "")"

  if grep -q "kibana.k8s" /etc/hosts 2>/dev/null; then
    pass "/etc/hosts contains kibana.k8s entry"
  else
    warn "/etc/hosts does not contain 'kibana.k8s'."
    warn "Add the following line to access Kibana via the Ingress:"
    warn "  ${node_ip}  kibana.k8s httpd.k8s"
    if [[ -n "$node_port" ]]; then
      warn "Then open: http://kibana.k8s:${node_port}"
    else
      warn "Then open: http://kibana.k8s"
    fi
  fi
}

# =============================================================================
# 7. SUMMARY
# =============================================================================
print_summary() {
  hr
  info "Deployment summary (namespace: $NAMESPACE)"
  hr
  kubectl get pods,services,ingress -n "$NAMESPACE" 2>/dev/null || true
  hr

  # Use only the IPv4 address (OrbStack / some clusters expose both IPv4+IPv6)
  local node_ip
  node_ip="$(kubectl get nodes \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
    2>/dev/null |
    tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 ||
    echo "127.0.0.1")"
  local node_port
  node_port="$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "<NodePort>")"

  echo ""
  info "Access URLs (requires /etc/hosts or DNS):"
  echo "  Kibana  → http://kibana.k8s:${node_port}   (Ingress)"
  echo "  httpd   → http://httpd.k8s:${node_port}    (Ingress)"
  echo ""
  info "Quick /etc/hosts entry:"
  echo "  ${node_ip}  kibana.k8s httpd.k8s"
  echo ""
  info "Useful commands:"
  echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=fluentd -f"
  echo "  kubectl logs -n $NAMESPACE -l app.kubernetes.io/name=log-generator -f"
  echo "  kubectl exec -n $NAMESPACE deploy/$RELEASE_ES -- curl -s http://localhost:9200/fluentd-*/_count"
  echo ""
  hr
  if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✓  All ${PASS_COUNT} tests passed.${NC}"
  else
    echo -e "${RED}${BOLD}✗  ${FAIL_COUNT} test(s) failed, ${PASS_COUNT} passed.${NC}"
    echo "   Review the errors above and check pod logs for details."
  fi
  hr
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  hr
  echo -e "${BOLD}  EFK Stack – Deploy & Test Script${NC}"
  echo "  Namespace : $NAMESPACE"
  echo "  Skip build: $SKIP_BUILD"
  echo "  Skip ingress-ctrl: $SKIP_INGRESS_CTRL"
  hr

  check_prereqs

  if ! $SKIP_BUILD; then
    build_and_load_fluentd
  else
    info "Skipping image build (--skip-build)"
  fi

  create_namespace

  if ! $SKIP_INGRESS_CTRL; then
    install_ingress_controller
  else
    info "Skipping ingress controller install (--skip-ingress-ctrl)"
  fi

  deploy_all
  wait_for_pods
  run_tests
  print_summary

  # Return non-zero if any test failed
  [[ $FAIL_COUNT -eq 0 ]]
}

main "$@"
