#!/usr/bin/env bash

set -Eeuo pipefail

readonly EXPECTED_CONTEXT='k3d-devops-platform'
readonly NAMESPACE='devops-platform'
readonly RELEASE_NAME='devops-platform'
readonly DB_SECRET='devops-platform-db'
readonly SERVICE_ACCOUNT='jenkins-deployer'
readonly TOKEN_SECRET='jenkins-deployer-token'
readonly JENKINS_CONTAINER='devops-platform-jenkins'
readonly K3D_LOAD_BALANCER='k3d-devops-platform-serverlb'
readonly OUTPUT_FILE='/tmp/devops-platform-jenkins-kubeconfig'
readonly CONTAINER_KUBECONFIG='/tmp/devops-platform-jenkins-kubeconfig'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly REPO_ROOT

fail() {
  printf '[phase4-kubeconfig] ERROR: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '[phase4-kubeconfig] %s\n' "$1"
}

for command_name in kubectl docker jq mktemp stat; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "required command is missing: $command_name"
done

current_context="$(kubectl config current-context)"
[[ "$current_context" == "$EXPECTED_CONTEXT" ]] \
  || fail "current context must be $EXPECTED_CONTEXT, got $current_context"

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || fail "namespace $NAMESPACE does not exist"
kubectl get secret "$DB_SECRET" -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "database Secret $DB_SECRET does not exist"

release_secret="$(kubectl get secrets -n "$NAMESPACE" \
  -l "owner=helm,name=$RELEASE_NAME" -o name | head -n 1)"
[[ -n "$release_secret" ]] || fail "Helm release $RELEASE_NAME does not exist"

pvc_name="$(kubectl get persistentvolumeclaims -n "$NAMESPACE" \
  -l "app.kubernetes.io/instance=$RELEASE_NAME" -o name | head -n 1)"
[[ -n "$pvc_name" ]] || fail 'application PVC does not exist'

docker inspect "$JENKINS_CONTAINER" >/dev/null 2>&1 \
  || fail "Jenkins container $JENKINS_CONTAINER does not exist"
jenkins_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
  "$JENKINS_CONTAINER")"
[[ "$jenkins_health" == 'healthy' ]] \
  || fail "Jenkins container is not healthy: $jenkins_health"

log 'Applying the namespace-scoped Jenkins deployment identity'
kubectl apply -f "$REPO_ROOT/deploy/kubernetes/jenkins-rbac.yaml" >/dev/null
kubectl get serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "ServiceAccount $SERVICE_ACCOUNT was not created"

token_data=''
for _ in {1..30}; do
  token_data="$(kubectl get secret "$TOKEN_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "$token_data" ]] && break
  sleep 1
done
[[ -n "$token_data" ]] || fail 'service-account token was not populated within 30 seconds'

token="$(kubectl get secret "$TOKEN_SECRET" -n "$NAMESPACE" -o json \
  | jq -er '.data.token | @base64d')"
ca_data="$(kubectl config view --raw --minify -o json \
  | jq -er '.clusters[0].cluster["certificate-authority-data"]')"
api_port="$(docker inspect "$K3D_LOAD_BALANCER" \
  | jq -er '.[0].NetworkSettings.Ports["6443/tcp"][0].HostPort')"
[[ "$api_port" =~ ^[0-9]+$ ]] || fail 'could not determine the published k3d API port'

umask 077
temporary_file="$(mktemp /tmp/devops-platform-jenkins-kubeconfig.XXXXXX)"
container_copy_created='false'
cleanup() {
  rm -f -- "$temporary_file"
  if [[ "$container_copy_created" == 'true' ]]; then
    docker exec --user root "$JENKINS_CONTAINER" rm -f -- "$CONTAINER_KUBECONFIG" \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

jq -n \
  --arg server "https://host.docker.internal:$api_port" \
  --arg tls_server_name "$K3D_LOAD_BALANCER" \
  --arg ca_data "$ca_data" \
  --arg token "$token" \
  --arg namespace "$NAMESPACE" \
  '{
    apiVersion: "v1",
    kind: "Config",
    clusters: [{
      name: "devops-platform",
      cluster: {
        server: $server,
        "tls-server-name": $tls_server_name,
        "certificate-authority-data": $ca_data
      }
    }],
    users: [{
      name: "jenkins-deployer",
      user: {token: $token}
    }],
    contexts: [{
      name: "jenkins-deployer@devops-platform",
      context: {
        cluster: "devops-platform",
        user: "jenkins-deployer",
        namespace: $namespace
      }
    }],
    "current-context": "jenkins-deployer@devops-platform"
  }' >"$temporary_file"

chmod 600 "$temporary_file"
mv -f -- "$temporary_file" "$OUTPUT_FILE"
temporary_file="$OUTPUT_FILE.unused"

docker cp "$OUTPUT_FILE" "$JENKINS_CONTAINER:$CONTAINER_KUBECONFIG" >/dev/null
container_copy_created='true'
docker exec --user root "$JENKINS_CONTAINER" chown jenkins:jenkins "$CONTAINER_KUBECONFIG"
docker exec --user root "$JENKINS_CONTAINER" chmod 600 "$CONTAINER_KUBECONFIG"

docker exec --user jenkins "$JENKINS_CONTAINER" \
  kubectl --kubeconfig "$CONTAINER_KUBECONFIG" auth can-i get pods -n "$NAMESPACE" \
  | grep -Fxq 'yes' || fail 'Jenkins identity cannot read target Pods'
docker exec --user jenkins "$JENKINS_CONTAINER" \
  kubectl --kubeconfig "$CONTAINER_KUBECONFIG" get pods -n "$NAMESPACE" >/dev/null \
  || fail 'Jenkins identity failed to list target Pods'
docker exec --user jenkins "$JENKINS_CONTAINER" \
  kubectl --kubeconfig "$CONTAINER_KUBECONFIG" auth can-i get pods -n monitoring \
  | grep -Fxq 'yes' || fail 'Jenkins identity cannot observe monitoring Pods'
docker exec --user jenkins "$JENKINS_CONTAINER" \
  kubectl --kubeconfig "$CONTAINER_KUBECONFIG" auth can-i create pods --subresource=portforward -n monitoring \
  | grep -Fxq 'yes' || fail 'Jenkins identity cannot create monitoring port-forward'
monitoring_secret_access="$(docker exec --user jenkins "$JENKINS_CONTAINER" \
  kubectl --kubeconfig "$CONTAINER_KUBECONFIG" auth can-i get secrets -n monitoring || true)"
[[ "$monitoring_secret_access" == 'no' ]] \
  || fail 'Jenkins identity unexpectedly reads monitoring Secrets'
node_access="$(docker exec --user jenkins "$JENKINS_CONTAINER" \
  kubectl --kubeconfig "$CONTAINER_KUBECONFIG" auth can-i get nodes || true)"
[[ "$node_access" == 'no' ]] || fail 'Jenkins identity unexpectedly has cluster Node access'

[[ "$(stat -c '%a' "$OUTPUT_FILE")" == '600' ]] \
  || fail 'generated kubeconfig permissions are not 600'

log 'Validated deployment access, monitoring observation, and denied Secret/Node access'
log "Generated credential file: $OUTPUT_FILE"
log 'Next: upload this file to Jenkins as a Secret file credential, then delete it locally.'
