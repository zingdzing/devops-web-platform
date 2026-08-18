# Phase 3 Kubernetes and Helm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the existing frontend, Flask backend, and MySQL application on a reproducible local k3d/K3s cluster behind the maintained F5 NGINX Ingress Controller, with Helm-managed configuration, probes, persistent data, automated recovery tests, and operator documentation.

**Architecture:** Docker Desktop hosts a one-server k3d cluster running K3s v1.36.1. The F5 NGINX Ingress Controller is installed as separately managed cluster infrastructure; one application Helm release deploys a frontend Deployment, backend Deployment, MySQL StatefulSet with retained PVC, internal Services, ConfigMap, and standard Ingress. Local Phase 3 images are built by Docker and imported into k3d; Phase 4 will replace this handoff with registry-backed CI/CD.

**Tech Stack:** Docker Desktop 29.7, k3d 5.9, K3s/Kubernetes 1.36.1, kubectl 1.36, Helm 4.2, F5 NGINX Ingress Controller 5.5.4 / chart 2.6.4, MySQL 8.4.11, Bash, jq, curl, ShellCheck, Make.

**Spec:** `docs/superpowers/specs/2026-08-18-phase-3-kubernetes-helm-design.md`

## Global Constraints

- Keep the application to one frontend replica, one backend replica, and one MySQL replica; this demonstrates reconciliation and recovery, not production high availability.
- Bind the only host entry point to `127.0.0.1:8080`; do not create NodePort Services for the application.
- Use `rancher/k3s:v1.36.1-k3s1`, `kubectl` v1.36.x, Helm v4.2.x, and k3d v5.9.x.
- Install F5 NGINX Ingress Controller chart `oci://ghcr.io/nginx/charts/nginx-ingress` at chart version `2.6.4` (controller `5.5.4`); never install retired community `kubernetes/ingress-nginx`.
- Disable K3s Traefik and keep the ingress controller outside the application Chart.
- Use the existing `mysql:8.4.11`, `python:3.14.6-slim`, and `nginxinc/nginx-unprivileged:1.28.1-alpine` image versions; do not use `latest`.
- Keep real passwords in the ignored root `.env` only. Do not commit `.env`, rendered Secret YAML, kubeconfig, tokens, recovery codes, or private keys.
- Use ConfigMap for non-secret database connection settings and a pre-created Secret named `devops-platform-db` for credentials.
- Use StatefulSet `volumeClaimTemplates` with `local-path`, 1Gi storage, and explicit Retain behavior. Promise persistence across Pod recreation only, not cluster deletion.
- Keep frontend and backend non-root. Do not claim NetworkPolicy isolation because Phase 3 does not install NetworkPolicy.
- Run preflight checks before registering cleanup traps. Default stop operations must preserve the cluster and PVC.
- Preserve all Phase 1 tests and Phase 2 behavior. README may claim Phase 3 only after the full release gate passes.
- Record only failures actually observed during execution; do not manufacture troubleshooting entries.

---

## File Map

**Create**

- `deploy/k3d/cluster.yaml` — declarative one-server k3d cluster, K3s image, Traefik disablement, and loopback ingress port mapping.
- `deploy/helm/devops-web-platform/.helmignore` — excludes local and generated artifacts from the Chart package.
- `deploy/helm/devops-web-platform/Chart.yaml` — application Chart identity and version.
- `deploy/helm/devops-web-platform/values.yaml` — non-secret images, ports, resources, ingress, MySQL, and existing Secret defaults.
- `deploy/helm/devops-web-platform/values.schema.json` — rejects missing values and `latest` image tags before rendering.
- `deploy/helm/devops-web-platform/files/init.sql` — packaged copy of the canonical MySQL schema.
- `deploy/helm/devops-web-platform/templates/_helpers.tpl` — stable names and standard labels.
- `deploy/helm/devops-web-platform/templates/configmap.yaml` — non-secret backend database configuration.
- `deploy/helm/devops-web-platform/templates/frontend-deployment.yaml` — frontend Pod template, security context, resources, and probes.
- `deploy/helm/devops-web-platform/templates/frontend-service.yaml` — internal frontend ClusterIP.
- `deploy/helm/devops-web-platform/templates/backend-deployment.yaml` — backend Pod template, ConfigMap/Secret injection, resources, and probes.
- `deploy/helm/devops-web-platform/templates/backend-service.yaml` — internal backend ClusterIP.
- `deploy/helm/devops-web-platform/templates/mysql-init-configmap.yaml` — packages `files/init.sql` for first database initialization.
- `deploy/helm/devops-web-platform/templates/mysql-service.yaml` — headless MySQL discovery Service.
- `deploy/helm/devops-web-platform/templates/mysql-statefulset.yaml` — MySQL process, authenticated probes, retained volume claim, and resources.
- `deploy/helm/devops-web-platform/templates/ingress.yaml` — standard Ingress paths for frontend, API, and health endpoints.
- `deploy/helm/devops-web-platform/templates/NOTES.txt` — post-install URL and diagnostic commands.
- `scripts/create-phase3-cluster.sh` — idempotently creates/starts k3d and installs the fixed F5 controller chart.
- `scripts/check-phase3-manifests.sh` — offline Chart contract and secret-safety checks.
- `scripts/deploy-phase3.sh` — builds/imports images, creates the runtime Secret, and performs a Helm 4 rollback-on-failure deployment.
- `scripts/stop-phase3.sh` — stops k3d without deleting the cluster or PVC.
- `scripts/verify-phase3.sh` — real CRUD, recovery, persistence, exposure, and security acceptance test.
- `docs/implementation/phase-3-kubernetes.md` — verified implementation evidence and resume mapping.
- `docs/troubleshooting/phase-3-kubernetes.md` — only real Phase 3 incidents.
- `docs/runbooks/phase-3-operations.md` — safe daily operations and destructive-command warnings.
- `docs/reviews/phase-3-independent-review.md` — final independent review findings and dispositions.

**Modify**

- `.env.example` — document Phase 3 use without adding real credentials.
- `Makefile` — expose cluster, manifest, deploy, status, logs, stop, and verify commands.
- `app/frontend/src/index.html` — change the visible deployment stage from Phase 2 to verified Phase 3 capabilities.
- `README.md` — publish Phase 3 usage and status only after acceptance passes.
- `deploy/README.md` — document the Compose/Helm boundary and safe commands.
- `docs/architecture.md` — replace the planned Kubernetes flow with the verified implemented flow.
- `docs/superpowers/specs/2026-08-18-phase-3-kubernetes-helm-design.md` — clarify that degraded backend health is checked directly inside the still-running Pod because an unready Pod is removed from Service endpoints.

---

### Task 1: Pin and create the local Kubernetes infrastructure

**Files:**
- Create: `deploy/k3d/cluster.yaml`
- Create: `scripts/create-phase3-cluster.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: Docker daemon; `k3d` v5.9.x; `kubectl` v1.36.x; Helm v4.2.x; loopback port 8080.
- Produces: cluster `devops-platform`, context `k3d-devops-platform`, namespace `nginx-ingress`, release `nginx-ingress`, and IngressClass `nginx` owned by `nginx.org/ingress-controller`.

- [ ] **Step 1: Confirm the current preflight fails cleanly when Docker is unavailable and passes with Docker Desktop running**

Run:

```bash
make check
```

Expected with Docker Desktop running: 16 `[PASS]` lines and `All DevOps project prerequisites passed.` Confirm the reported families are kubectl 1.36, Helm 4.2, and k3d 5.9. Do not install another copy when these checks pass.

- [ ] **Step 2: Add the declarative k3d cluster configuration**

Create `deploy/k3d/cluster.yaml`:

```yaml
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: devops-platform
servers: 1
agents: 0
image: rancher/k3s:v1.36.1-k3s1
ports:
  - port: 127.0.0.1:8080:80
    nodeFilters:
      - loadbalancer
options:
  k3s:
    extraArgs:
      - arg: --disable=traefik
        nodeFilters:
          - server:*
  kubeconfig:
    updateDefaultKubeconfig: true
    switchCurrentContext: true
```

- [ ] **Step 3: Validate the cluster configuration before creating anything**

Run:

```bash
k3d config migrate deploy/k3d/cluster.yaml /tmp/devops-phase3-k3d.yaml
grep -F 'rancher/k3s:v1.36.1-k3s1' /tmp/devops-phase3-k3d.yaml
grep -F -- '--disable=traefik' /tmp/devops-phase3-k3d.yaml
rm -f /tmp/devops-phase3-k3d.yaml
```

Expected: k3d parses the v1alpha5 file without creating a cluster, both pinned values are printed, and the command exits 0. k3d 5.9 does not provide the older `config process` subcommand; `config migrate` is the supported parse-and-normalize check.

- [ ] **Step 4: Write the idempotent cluster/controller script**

Create `scripts/create-phase3-cluster.sh` with strict mode, these constants, and this control flow:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

readonly CLUSTER_NAME='devops-platform'
readonly CLUSTER_CONTEXT='k3d-devops-platform'
readonly CLUSTER_CONFIG='deploy/k3d/cluster.yaml'
readonly NIC_NAMESPACE='nginx-ingress'
readonly NIC_RELEASE='nginx-ingress'
readonly NIC_CHART='oci://ghcr.io/nginx/charts/nginx-ingress'
readonly NIC_CHART_VERSION='2.6.4'

fail() { printf '[phase3-cluster] ERROR: %s\n' "$1" >&2; exit 1; }
log() { printf '[phase3-cluster] %s\n' "$1"; }

for command_name in docker jq k3d kubectl helm; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is missing"
done
docker info >/dev/null 2>&1 || fail 'Docker Desktop is not reachable'
[[ -f "$CLUSTER_CONFIG" ]] || fail "$CLUSTER_CONFIG is missing"

if k3d cluster list -o json | jq -e --arg name "$CLUSTER_NAME" '.[] | select(.name == $name)' >/dev/null; then
  log 'starting the existing cluster'
  k3d cluster start "$CLUSTER_NAME"
else
  if docker ps --format '{{.Names}} {{.Ports}}' | grep -Fq '127.0.0.1:8080->'; then
    fail '127.0.0.1:8080 is already published; stop Phase 2 with make phase2-down'
  fi
  log 'creating the pinned cluster'
  k3d cluster create --config "$CLUSTER_CONFIG"
fi

kubectl config use-context "$CLUSTER_CONTEXT" >/dev/null
kubectl wait --for=condition=Ready node --all --timeout=180s
if kubectl --namespace kube-system get deployment traefik >/dev/null 2>&1; then
  fail 'Traefik is present although the cluster config disables it'
fi

helm upgrade --install "$NIC_RELEASE" "$NIC_CHART" \
  --namespace "$NIC_NAMESPACE" \
  --create-namespace \
  --version "$NIC_CHART_VERSION" \
  --skip-crds \
  --set controller.enableCustomResources=false \
  --set controller.appprotect.enable=false \
  --set controller.appprotectdos.enable=false \
  --set controller.service.type=LoadBalancer \
  --rollback-on-failure --wait=watcher --timeout 5m

kubectl --namespace "$NIC_NAMESPACE" wait \
  --for=condition=Available deployment --all --timeout=180s
[[ "$(kubectl get ingressclass nginx -o jsonpath='{.spec.controller}')" == 'nginx.org/ingress-controller' ]] \
  || fail 'IngressClass nginx is not owned by the F5 controller'
log 'cluster and ingress controller are ready'
```

- [ ] **Step 5: Add only the Task 1 Make targets and validate shell syntax**

Add `phase3-cluster-create` to `.PHONY` and to `help`, then add:

```make
phase3-cluster-create:
	@bash scripts/create-phase3-cluster.sh
```

Run:

```bash
bash -n scripts/create-phase3-cluster.sh
shellcheck scripts/create-phase3-cluster.sh
```

Expected: both commands exit 0.

- [ ] **Step 6: Create the real cluster and verify its identity**

Ensure Phase 2 is stopped first so port 8080 is free:

```bash
make phase2-down
make phase3-cluster-create
kubectl config current-context
kubectl get nodes -o wide
kubectl get ingressclass nginx
kubectl -n kube-system get deployment traefik
```

Expected: context is `k3d-devops-platform`, one node is Ready, IngressClass controller is `nginx.org/ingress-controller`, and the final command returns NotFound.

- [ ] **Step 7: Commit the infrastructure boundary**

```bash
git add deploy/k3d/cluster.yaml scripts/create-phase3-cluster.sh Makefile
git commit -m "feat: create phase 3 k3d ingress infrastructure"
```

---

### Task 2: Define the Helm Chart contract and validation schema

**Files:**
- Create: `deploy/helm/devops-web-platform/.helmignore`
- Create: `deploy/helm/devops-web-platform/Chart.yaml`
- Create: `deploy/helm/devops-web-platform/values.yaml`
- Create: `deploy/helm/devops-web-platform/values.schema.json`
- Create: `deploy/helm/devops-web-platform/templates/_helpers.tpl`

**Interfaces:**
- Consumes: existing runtime image names and fixed resource values from the spec.
- Produces: Chart `devops-web-platform` version `0.3.0`; release fullname helper; exact `.Values.images`, `.Values.existingSecret`, `.Values.services`, `.Values.ingress`, `.Values.mysql`, and `.Values.resources` contracts used by Tasks 3–7.

- [ ] **Step 1: Demonstrate that the Chart does not exist yet**

Run:

```bash
helm lint deploy/helm/devops-web-platform
```

Expected: FAIL because `Chart.yaml` is absent.

- [ ] **Step 2: Create Chart metadata and ignore rules**

Create `Chart.yaml`:

```yaml
apiVersion: v2
name: devops-web-platform
description: Local Kubernetes deployment for the DevOps operations task board
type: application
version: 0.3.0
appVersion: "3.0.0"
```

Create `.helmignore`:

```text
.DS_Store
.git/
.env
*.tmp
*.swp
rendered*.yaml
```

- [ ] **Step 3: Create the non-secret values contract**

Create `values.yaml` with these exact keys and initial values:

```yaml
nameOverride: ""
fullnameOverride: ""
existingSecret: devops-platform-db

images:
  frontend:
    repository: devops-web-platform-frontend
    tag: phase3
    pullPolicy: IfNotPresent
  backend:
    repository: devops-web-platform-backend
    tag: phase3
    pullPolicy: IfNotPresent
  mysql:
    repository: mysql
    tag: 8.4.11
    pullPolicy: IfNotPresent

services:
  frontendPort: 8080
  backendPort: 5000
  mysqlPort: 3306

ingress:
  enabled: true
  className: nginx

mysql:
  database: ops_tasks
  storageClassName: local-path
  storageSize: 1Gi

resources:
  frontend:
    requests: {cpu: 25m, memory: 32Mi}
    limits: {cpu: 100m, memory: 64Mi}
  backend:
    requests: {cpu: 50m, memory: 64Mi}
    limits: {cpu: 250m, memory: 256Mi}
  mysql:
    requests: {cpu: 100m, memory: 256Mi}
    limits: {cpu: 500m, memory: 512Mi}
```

- [ ] **Step 4: Add JSON schema checks that reject absent and latest tags**

Create `values.schema.json` as:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "additionalProperties": false,
  "required": ["existingSecret", "images", "services", "ingress", "mysql", "resources"],
  "properties": {
    "nameOverride": {"type": "string"},
    "fullnameOverride": {"type": "string"},
    "existingSecret": {"type": "string", "minLength": 1},
    "images": {
      "type": "object",
      "additionalProperties": false,
      "required": ["frontend", "backend", "mysql"],
      "properties": {
        "frontend": {"$ref": "#/definitions/image"},
        "backend": {"$ref": "#/definitions/image"},
        "mysql": {"$ref": "#/definitions/image"}
      }
    },
    "services": {
      "type": "object",
      "additionalProperties": false,
      "required": ["frontendPort", "backendPort", "mysqlPort"],
      "properties": {
        "frontendPort": {"$ref": "#/definitions/port"},
        "backendPort": {"$ref": "#/definitions/port"},
        "mysqlPort": {"$ref": "#/definitions/port"}
      }
    },
    "ingress": {
      "type": "object",
      "additionalProperties": false,
      "required": ["enabled", "className"],
      "properties": {
        "enabled": {"type": "boolean"},
        "className": {"const": "nginx"}
      }
    },
    "mysql": {
      "type": "object",
      "additionalProperties": false,
      "required": ["database", "storageClassName", "storageSize"],
      "properties": {
        "database": {"type": "string", "minLength": 1},
        "storageClassName": {"const": "local-path"},
        "storageSize": {"type": "string", "pattern": "^[1-9][0-9]*(Mi|Gi)$"}
      }
    },
    "resources": {
      "type": "object",
      "additionalProperties": false,
      "required": ["frontend", "backend", "mysql"],
      "properties": {
        "frontend": {"$ref": "#/definitions/resources"},
        "backend": {"$ref": "#/definitions/resources"},
        "mysql": {"$ref": "#/definitions/resources"}
      }
    }
  },
  "definitions": {
    "image": {
      "type": "object",
      "additionalProperties": false,
      "required": ["repository", "tag", "pullPolicy"],
      "properties": {
        "repository": {"type": "string", "minLength": 1},
        "tag": {"type": "string", "minLength": 1, "not": {"const": "latest"}},
        "pullPolicy": {"const": "IfNotPresent"}
      }
    },
    "port": {"type": "integer", "minimum": 1, "maximum": 65535},
    "resources": {
      "type": "object",
      "additionalProperties": false,
      "required": ["requests", "limits"],
      "properties": {
        "requests": {"$ref": "#/definitions/resourcePair"},
        "limits": {"$ref": "#/definitions/resourcePair"}
      }
    },
    "resourcePair": {
      "type": "object",
      "additionalProperties": false,
      "required": ["cpu", "memory"],
      "properties": {
        "cpu": {"type": "string", "minLength": 1},
        "memory": {"type": "string", "minLength": 1}
      }
    }
  }
}
```

- [ ] **Step 5: Add stable naming and labels**

Create `_helpers.tpl` with helpers:

```gotemplate
{{- define "devops-web-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "devops-web-platform.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "devops-web-platform.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "devops-web-platform.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "devops-web-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
```

- [ ] **Step 6: Prove schema enforcement and then lint the valid defaults**

Run:

```bash
helm lint deploy/helm/devops-web-platform
helm lint deploy/helm/devops-web-platform --set images.backend.tag=latest
```

Expected: the first command passes; the second fails because `latest` is forbidden.

- [ ] **Step 7: Commit the Chart interface**

```bash
git add deploy/helm/devops-web-platform
git commit -m "feat: define phase 3 helm chart contract"
```

---

### Task 3: Render secure frontend and backend workloads

**Files:**
- Create: `deploy/helm/devops-web-platform/templates/configmap.yaml`
- Create: `deploy/helm/devops-web-platform/templates/frontend-deployment.yaml`
- Create: `deploy/helm/devops-web-platform/templates/frontend-service.yaml`
- Create: `deploy/helm/devops-web-platform/templates/backend-deployment.yaml`
- Create: `deploy/helm/devops-web-platform/templates/backend-service.yaml`
- Modify: `app/frontend/src/index.html`

**Interfaces:**
- Consumes: Secret keys `DB_USER` and `DB_PASSWORD`; ConfigMap keys `DB_HOST`, `DB_PORT`, `DB_NAME`; images and ports from Task 2.
- Produces: Services `devops-platform-devops-web-platform-frontend:8080` and `backend:5000`; the fixed backend name preserves compatibility with the Phase 2 frontend Nginx upstream inside the dedicated namespace. Component selector labels `frontend` and `backend` are used by verification.

- [ ] **Step 1: Add a render assertion that initially fails**

Run:

```bash
helm template devops-platform deploy/helm/devops-web-platform --namespace devops-platform \
  | grep -F 'kind: Deployment'
```

Expected: FAIL because no workload templates exist.

- [ ] **Step 2: Create the application ConfigMap**

Render a ConfigMap named from `devops-web-platform.fullname` with suffix `config`:

```yaml
data:
  DB_HOST: "{{ include "devops-web-platform.fullname" . }}-mysql"
  DB_PORT: "{{ .Values.services.mysqlPort }}"
  DB_NAME: "{{ .Values.mysql.database }}"
```

Apply standard labels from `_helpers.tpl`.

- [ ] **Step 3: Create the frontend Deployment and Service**

Use selector `app.kubernetes.io/component: frontend`, one replica, and this container contract:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  runAsNonRoot: true
  runAsUser: 101
  runAsGroup: 101
ports:
  - name: http
    containerPort: 8080
startupProbe:
  httpGet: {path: /, port: http}
  failureThreshold: 30
  periodSeconds: 2
readinessProbe:
  httpGet: {path: /, port: http}
  periodSeconds: 5
livenessProbe:
  httpGet: {path: /, port: http}
  periodSeconds: 10
```

Set `image` from `images.frontend`, use `resources.frontend`, set Pod `seccompProfile.type: RuntimeDefault`, and create a ClusterIP Service with port/targetPort 8080. Do not set `nodePort`, `hostPort`, or `hostNetwork`.

- [ ] **Step 4: Create the backend Deployment and Service**

Use selector `app.kubernetes.io/component: backend`, one replica, UID/GID 10001, dropped capabilities, RuntimeDefault seccomp, and port 5000. Inject `DB_HOST`, `DB_PORT`, and `DB_NAME` with `envFrom.configMapRef`; inject `DB_USER` and `DB_PASSWORD` individually from `.Values.existingSecret`:

```yaml
- name: DB_USER
  valueFrom:
    secretKeyRef: {name: "{{ .Values.existingSecret }}", key: DB_USER}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef: {name: "{{ .Values.existingSecret }}", key: DB_PASSWORD}
```

Use these probes:

```yaml
startupProbe:
  httpGet: {path: /healthz, port: http}
  failureThreshold: 30
  periodSeconds: 2
readinessProbe:
  httpGet: {path: /readyz, port: http}
  periodSeconds: 5
livenessProbe:
  httpGet: {path: /healthz, port: http}
  periodSeconds: 10
```

Create a ClusterIP Service with port/targetPort 5000 and no external port type.

- [ ] **Step 5: Update the page to describe the new deployment layer**

In `app/frontend/src/index.html`, change the description, eyebrow, capability chips, and footer to:

```html
<meta name="description" content="DevOps Web Platform Phase 3 Kubernetes operations task board">
<p class="eyebrow">DEVOPS WEB PLATFORM · PHASE 3</p>
<p class="intro">通过 Kubernetes、NGINX Ingress 与 Helm 部署运维任务清单，验证服务发现、健康检查、自动恢复和 MySQL 持久化。</p>
```

The four chips must read `NGINX Ingress`, `Kubernetes 编排`, `Helm 部署`, and `MySQL 持久化`; the footer must read `Phase 3：k3d + Kubernetes + NGINX Ingress + Helm + MySQL 8.4`.

- [ ] **Step 6: Render and inspect the exact contracts**

Run:

```bash
helm lint deploy/helm/devops-web-platform
helm template devops-platform deploy/helm/devops-web-platform --namespace devops-platform >/tmp/phase3.yaml
grep -c '^kind: Deployment$' /tmp/phase3.yaml
grep -c '^kind: Service$' /tmp/phase3.yaml
grep -F 'runAsUser: 10001' /tmp/phase3.yaml
grep -F 'secretKeyRef:' /tmp/phase3.yaml
! grep -E 'type: (NodePort|LoadBalancer)|hostPort:' /tmp/phase3.yaml
rm -f /tmp/phase3.yaml
```

Expected: two Deployments, two Services at this task boundary, both security identities present, Secret references present, and no externally exposed Service.

- [ ] **Step 7: Commit the stateless workloads**

```bash
git add app/frontend/src/index.html deploy/helm/devops-web-platform/templates
git commit -m "feat: add phase 3 frontend and backend workloads"
```

---

### Task 4: Add MySQL state, initialization, and authenticated health checks

**Files:**
- Create: `deploy/helm/devops-web-platform/files/init.sql`
- Create: `deploy/helm/devops-web-platform/templates/mysql-init-configmap.yaml`
- Create: `deploy/helm/devops-web-platform/templates/mysql-service.yaml`
- Create: `deploy/helm/devops-web-platform/templates/mysql-statefulset.yaml`

**Interfaces:**
- Consumes: Secret keys `DB_USER`, `DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`; `mysql.database`, storage, image, and resource values.
- Produces: headless Service `devops-platform-devops-web-platform-mysql`, StatefulSet with component label `mysql`, Pod ordinal 0, and PVC `mysql-data-devops-platform-devops-web-platform-mysql-0` retained when the StatefulSet is scaled or deleted.

- [ ] **Step 1: Copy and verify the canonical schema**

Copy `app/database/init.sql` to `deploy/helm/devops-web-platform/files/init.sql`, then run:

```bash
cmp --silent app/database/init.sql deploy/helm/devops-web-platform/files/init.sql
```

Expected: exit 0. This comparison remains in later manifest/deploy checks to prevent schema drift.

- [ ] **Step 2: Package the SQL without embedding credentials**

Create `mysql-init-configmap.yaml` with standard labels and:

```gotemplate
data:
  01-init.sql: |
{{ .Files.Get "files/init.sql" | indent 4 }}
```

- [ ] **Step 3: Add the headless MySQL Service**

Create a Service selecting component `mysql` with:

```yaml
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  ports:
    - name: mysql
      port: 3306
      targetPort: mysql
```

- [ ] **Step 4: Add the StatefulSet and retained claim template**

Create one-replica StatefulSet with `serviceName` equal to the headless Service, `podManagementPolicy: OrderedReady`, and:

```yaml
persistentVolumeClaimRetentionPolicy:
  whenDeleted: Retain
  whenScaled: Retain
```

The MySQL container uses image `mysql:8.4.11`, port `mysql:3306`, the Task 2 MySQL resources, and these environment variables:

```yaml
- name: MYSQL_DATABASE
  value: "{{ .Values.mysql.database }}"
- name: MYSQL_USER
  valueFrom:
    secretKeyRef: {name: "{{ .Values.existingSecret }}", key: DB_USER}
- name: MYSQL_PASSWORD
  valueFrom:
    secretKeyRef: {name: "{{ .Values.existingSecret }}", key: DB_PASSWORD}
- name: MYSQL_ROOT_PASSWORD
  valueFrom:
    secretKeyRef: {name: "{{ .Values.existingSecret }}", key: MYSQL_ROOT_PASSWORD}
```

Mount `mysql-data` at `/var/lib/mysql` and the init ConfigMap key at `/docker-entrypoint-initdb.d/01-init.sql` using `subPath`. Define the claim template:

```yaml
accessModes: ["ReadWriteOnce"]
storageClassName: "{{ .Values.mysql.storageClassName }}"
resources:
  requests:
    storage: "{{ .Values.mysql.storageSize }}"
```

- [ ] **Step 5: Separate process liveness from authenticated readiness**

Use `sh -ec` so the environment variable is expanded inside the container:

```yaml
startupProbe:
  exec:
    command: ["sh", "-ec", "MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\" mysql --protocol=TCP --host=127.0.0.1 --user=root --execute='SELECT 1' --silent"]
  failureThreshold: 60
  periodSeconds: 2
readinessProbe:
  exec:
    command: ["sh", "-ec", "MYSQL_PWD=\"$MYSQL_ROOT_PASSWORD\" mysql --protocol=TCP --host=127.0.0.1 --user=root --execute='SELECT 1' --silent"]
  periodSeconds: 5
livenessProbe:
  exec:
    command: ["sh", "-ec", "mysqladmin ping --host=127.0.0.1 --silent"]
  periodSeconds: 10
```

The liveness probe intentionally asks only whether the server process responds; startup/readiness require a real authenticated query.

- [ ] **Step 6: Render and validate state semantics**

Run:

```bash
helm lint deploy/helm/devops-web-platform
helm template devops-platform deploy/helm/devops-web-platform --namespace devops-platform >/tmp/phase3.yaml
grep -F 'kind: StatefulSet' /tmp/phase3.yaml
grep -F 'whenDeleted: Retain' /tmp/phase3.yaml
grep -F "execute='SELECT 1'" /tmp/phase3.yaml
grep -F 'storageClassName: "local-path"' /tmp/phase3.yaml
! grep -F 'change-me-' /tmp/phase3.yaml
rm -f /tmp/phase3.yaml
```

Expected: all positive checks print a match and no example password is rendered.

- [ ] **Step 7: Commit the stateful workload**

```bash
git add deploy/helm/devops-web-platform
git commit -m "feat: add retained mysql stateful workload"
```

---

### Task 5: Add unified Ingress and an offline manifest quality gate

**Files:**
- Create: `deploy/helm/devops-web-platform/templates/ingress.yaml`
- Create: `deploy/helm/devops-web-platform/templates/NOTES.txt`
- Create: `scripts/check-phase3-manifests.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: IngressClass `nginx`; frontend/backend Services from Task 3.
- Produces: one standard Ingress for host `localhost`; `make phase3-manifests`; rendered-resource and secret-safety gate used before every deployment.

- [ ] **Step 1: Demonstrate the missing routing resource**

Run:

```bash
helm template devops-platform deploy/helm/devops-web-platform --namespace devops-platform \
  | grep -F 'kind: Ingress'
```

Expected: FAIL.

- [ ] **Step 2: Add standard Ingress routing**

When `ingress.enabled` is true, render `networking.k8s.io/v1`, `ingressClassName: nginx`, and host `localhost` because F5 NGINX Ingress Controller requires a host value. Add Prefix paths in this order:

```yaml
- path: /api
  pathType: Prefix
  backend:
    service:
      name: backend
      port: {number: 5000}
- path: /healthz
  pathType: Prefix
  backend:
    service:
      name: backend
      port: {number: 5000}
- path: /readyz
  pathType: Prefix
  backend:
    service:
      name: backend
      port: {number: 5000}
- path: /
  pathType: Prefix
  backend:
    service:
      name: {{ include "devops-web-platform.fullname" . }}-frontend
      port: {number: 8080}
```

Do not add retired community-specific annotations.

- [ ] **Step 3: Add post-install operator notes**

`NOTES.txt` must print:

```text
DevOps Web Platform is available at http://localhost:8080
Status: kubectl get pods,svc,ingress,pvc -n {{ .Release.Namespace }}
Verify: make phase3-verify
```

- [ ] **Step 4: Write the offline manifest gate**

Create `scripts/check-phase3-manifests.sh` that:

1. Checks `helm`, `git`, `grep`, `cmp`, and `mktemp` before creating a temporary file.
2. Runs `cmp --silent app/database/init.sql deploy/helm/devops-web-platform/files/init.sql`.
3. Runs `helm lint deploy/helm/devops-web-platform`.
4. Renders release `devops-platform` in namespace `devops-platform` to the temporary file.
5. Requires exactly 2 Deployments, 3 Services, 1 StatefulSet, 1 ConfigMap for app configuration, 1 init ConfigMap, and 1 Ingress.
6. Requires `ingressClassName: nginx`, `whenDeleted: Retain`, all six request/limit values, and all expected Probe paths.
7. Fails on `type: NodePort`, application `type: LoadBalancer`, `hostPort`, `hostNetwork: true`, `tag: latest`, or any `change-me-` password.
8. Fails if `git ls-files` includes `.env`, kubeconfig, private-key-shaped filenames, or Secret render output.
9. Fails if `git grep` finds a GitHub token or private-key header.
10. Deletes only its own temporary file through an EXIT trap registered after all command/file prechecks.

Use the same token/private-key patterns already proven in `verify-phase2.sh`; do not create a new broader pattern that flags documentation examples.

- [ ] **Step 5: Add and run the manifest target**

Add:

```make
phase3-manifests:
	@bash scripts/check-phase3-manifests.sh
```

Run:

```bash
bash -n scripts/check-phase3-manifests.sh
shellcheck scripts/check-phase3-manifests.sh
make phase3-manifests
```

Expected: all commands exit 0 and the script ends with `Phase 3 manifest checks passed`.

- [ ] **Step 6: Commit routing and static verification**

```bash
git add deploy/helm/devops-web-platform/templates scripts/check-phase3-manifests.sh Makefile
git commit -m "feat: add phase 3 ingress and manifest checks"
```

---

### Task 6: Automate secret creation, image import, deployment, and safe stop

**Files:**
- Create: `scripts/deploy-phase3.sh`
- Create: `scripts/stop-phase3.sh`
- Modify: `.env.example`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `.env` keys `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `MYSQL_ROOT_PASSWORD`; cluster/context from Task 1; Chart from Tasks 2–5.
- Produces: images `devops-web-platform-frontend:phase3` and `devops-web-platform-backend:phase3`, Secret `devops-platform-db`, Helm release `devops-platform` in namespace `devops-platform`, and safe stop/status/log targets.

- [ ] **Step 1: Prove deployment cannot start without a local `.env`**

Temporarily point the script draft at a nonexistent env file or run before creating it. Expected final behavior is a fast error before Docker builds, Secret creation, or cleanup registration:

```text
[phase3-deploy] ERROR: .env is missing; copy .env.example to .env first
```

- [ ] **Step 2: Write deployment preflight and private temporary Secret input**

Create `scripts/deploy-phase3.sh` with strict mode and constants for cluster, context, namespace, release, Chart, two image names, and Secret name. Before `mktemp` or `trap`, check `.env`, the canonical SQL copy, Docker, jq, k3d, kubectl, Helm, and curl; run `make phase3-manifests`; confirm the cluster exists and current context can be switched.

Load `.env` with `set -a; source .env; set +a`, then require non-empty `DB_NAME`, `DB_USER`, `DB_PASSWORD`, and `MYSQL_ROOT_PASSWORD`. Create a mode-600 temporary env file under `/tmp` containing only the three runtime values without printing them:

```bash
umask 077
secret_env_file="$(mktemp /tmp/devops-phase3-secret.XXXXXX)"
printf 'DB_USER=%s\nDB_PASSWORD=%s\nMYSQL_ROOT_PASSWORD=%s\n' \
  "$DB_USER" "$DB_PASSWORD" "$MYSQL_ROOT_PASSWORD" >"$secret_env_file"
```

Register cleanup only after the file exists; cleanup removes only that file. Never echo its contents.

- [ ] **Step 3: Build and import fixed local images**

Execute:

```bash
docker build --tag devops-web-platform-backend:phase3 app/backend
docker build --tag devops-web-platform-frontend:phase3 app/frontend
k3d image import --cluster devops-platform \
  devops-web-platform-backend:phase3 devops-web-platform-frontend:phase3
```

Then verify each image exists inside the server node with:

```bash
docker exec k3d-devops-platform-server-0 crictl images
```

and fail unless both repository/tag pairs are present.

- [ ] **Step 4: Create/update the runtime Secret without putting literals on the command line**

Run:

```bash
kubectl create namespace devops-platform --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic devops-platform-db \
  --namespace devops-platform \
  --from-env-file="$secret_env_file" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify only key names, never values:

```bash
kubectl get secret devops-platform-db -n devops-platform \
  -o json | jq -e '.data | keys | sort == ["DB_PASSWORD","DB_USER","MYSQL_ROOT_PASSWORD"]'
```

- [ ] **Step 5: Perform a Helm 4 rollback-on-failure install/upgrade**

Run:

```bash
helm upgrade --install devops-platform deploy/helm/devops-web-platform \
  --namespace devops-platform \
  --create-namespace \
  --set-string mysql.database="$DB_NAME" \
  --rollback-on-failure --wait=watcher --timeout 5m
kubectl rollout status deployment/devops-platform-devops-web-platform-frontend -n devops-platform --timeout=180s
kubectl rollout status deployment/devops-platform-devops-web-platform-backend -n devops-platform --timeout=180s
kubectl rollout status statefulset/devops-platform-devops-web-platform-mysql -n devops-platform --timeout=300s
curl --fail --silent http://localhost:8080/readyz >/dev/null
```

- [ ] **Step 6: Add safe stop and Make targets**

`scripts/stop-phase3.sh` must check k3d and run only:

```bash
k3d cluster stop devops-platform
```

It must explicitly print that the cluster and PVC remain and must not call `helm uninstall`, `kubectl delete pvc`, or `k3d cluster delete`.

Add Make targets:

```make
phase3-deploy:
	@bash scripts/deploy-phase3.sh

phase3-status:
	@kubectl get pods,svc,ingress,pvc -n devops-platform

phase3-logs:
	@kubectl logs -n devops-platform deployment/devops-platform-devops-web-platform-backend --follow

phase3-stop:
	@bash scripts/stop-phase3.sh
```

Update `.env.example` first comment to `Safe local examples for Phase 1, Phase 2, and Phase 3`; do not add new secrets.

- [ ] **Step 7: Deploy twice to prove idempotency**

Run:

```bash
bash -n scripts/deploy-phase3.sh scripts/stop-phase3.sh
shellcheck scripts/deploy-phase3.sh scripts/stop-phase3.sh
make phase3-deploy
make phase3-deploy
helm history devops-platform -n devops-platform
make phase3-status
```

Expected: both deployments pass; Helm history shows a second successful revision; all three workloads are Ready; one PVC is Bound.

- [ ] **Step 8: Commit deployment automation**

```bash
git add .env.example Makefile scripts/deploy-phase3.sh scripts/stop-phase3.sh
git commit -m "feat: automate phase 3 helm deployment"
```

---

### Task 7: Automate Kubernetes recovery and persistence acceptance

**Files:**
- Create: `scripts/verify-phase3.sh`
- Modify: `Makefile`
- Modify: `docs/superpowers/specs/2026-08-18-phase-3-kubernetes-helm-design.md`

**Interfaces:**
- Consumes: deployed release, component labels, `/api/items`, `/healthz`, `/readyz`, Python in backend image, and retained MySQL PVC.
- Produces: `make phase3-verify`, a deterministic acceptance result, and a precise clarification of Kubernetes readiness behavior.

- [ ] **Step 1: Clarify the health-check observation point in the design**

Add this paragraph under backend health behavior in the spec:

```text
Kubernetes Service 默认只把 Ready Pod 放入可用端点。单副本 backend 因数据库故障变为 NotReady 后，Ingress 无法继续访问它，因此故障验收通过 kubectl exec 在仍运行的 backend Pod 内直接检查 /healthz=200 和 /readyz=503；外部入口此时返回 503。该现象表示流量隔离生效，不表示 Flask 进程已经退出。
```

- [ ] **Step 2: Write verifier preflight before any trap**

The script must check `.env`, curl, jq, python3, git, kubectl, Helm, k3d, the current context, cluster node Ready, release deployed, and base URL reachable before it creates a response file or registers cleanup. Constants:

```bash
readonly NAMESPACE='devops-platform'
readonly RELEASE='devops-platform'
readonly BASE_URL='http://localhost:8080'
readonly BACKEND_SELECTOR='app.kubernetes.io/component=backend'
readonly MYSQL_SELECTOR='app.kubernetes.io/component=mysql'
readonly BACKEND_DEPLOYMENT_NAME='devops-platform-devops-web-platform-backend'
readonly MYSQL_STATEFUL_NAME='devops-platform-devops-web-platform-mysql'
```

- [ ] **Step 3: Implement reusable HTTP and Pod-local status helpers**

Reuse `expect_status` and `wait_for_status` semantics from Phase 2. Add `pod_http_status` that executes this inside the backend Pod:

```python
import sys
import urllib.error
import urllib.request
try:
    response = urllib.request.urlopen(sys.argv[1], timeout=5)
    print(response.status)
except urllib.error.HTTPError as error:
    print(error.code)
```

Call it with `http://127.0.0.1:5000/healthz` or `/readyz`. This direct check is mandatory during database failure because Kubernetes removes NotReady backend Pods from Service endpoints.

- [ ] **Step 4: Implement conservative cleanup state**

Track `created_id`, `persistent_id`, `mysql_scaled_down`, and `response_file`. Cleanup must:

1. Scale MySQL back to 1 only if the verifier scaled it down.
2. Wait for the StatefulSet and backend readiness before deleting temporary API records.
3. Delete only IDs created by this run.
4. Remove only its own temporary response file.
5. Never uninstall Helm, delete a PVC, or delete the cluster.

- [ ] **Step 5: Verify cluster boundary, controller, resources, and runtime users**

The verifier must assert:

```text
current context = k3d-devops-platform
one Ready node
no kube-system/traefik Deployment
IngressClass nginx controller = nginx.org/ingress-controller
NGINX controller Deployment Available
application Helm release status = deployed
frontend/backend Deployments Available
MySQL StatefulSet readyReplicas = 1
PVC phase = Bound
all application Services are ClusterIP or headless; none is NodePort/LoadBalancer
frontend id -u != 0
backend id -u != 0
```

Parse Kubernetes JSON with jq/Python rather than matching human table spacing.

- [ ] **Step 6: Verify CRUD through Ingress**

Create `Phase 3 verification`, list it, update it to `completed`, and delete it using the same payload and numeric-ID assertions proven in `verify-phase2.sh`, but change descriptions to `Created by verify-phase3.sh` and `Updated by verify-phase3.sh`.

- [ ] **Step 7: Verify Deployment reconciliation**

Capture the backend Pod UID and name, delete that Pod with `--wait=true`, wait for a Pod matching the backend selector to become Ready, then wait for the Deployment rollout. Capture the replacement UID and require the UIDs to differ. Then require external `/healthz` and `/readyz` to return 200. Waiting for deletion and Ready prevents reading the terminating Pod from an eventually consistent selector result.

- [ ] **Step 8: Verify dependency degradation without killing Flask**

Capture the backend Pod name, scale the MySQL StatefulSet to 0, set `mysql_scaled_down=true`, and wait for the MySQL Pod to disappear. Poll Pod-local `/readyz` until 503, require Pod-local `/healthz` to remain 200, and require external `/readyz` to return 503. Restore MySQL to 1, wait for StatefulSet rollout and Pod-local readiness 200, then clear `mysql_scaled_down`.

- [ ] **Step 9: Verify StatefulSet recreation and PVC persistence**

Create a `Phase 3 persistence` item and retain its numeric ID. Capture MySQL Pod UID and name, delete the Pod with `--wait=true` without deleting the PVC, wait for a Pod matching the MySQL selector to become Ready, then wait for StatefulSet rollout. Require the replacement UID to differ and query `/api/items` until the persistent ID appears. Delete the test item and clear `persistent_id`.

- [ ] **Step 10: Verify repeated Helm upgrade and tracked-file safety**

Run the same `helm upgrade --install ... --set-string mysql.database="$DB_NAME" --rollback-on-failure --wait=watcher` command from Task 6, rerun `make phase3-manifests`, scan tracked files with the Phase 2 secret patterns, and require `.env`, kubeconfig, private-key-shaped filenames, and rendered Secret manifests to remain untracked.

- [ ] **Step 11: Add target and run the complete test**

Add:

```make
phase3-verify:
	@bash scripts/verify-phase3.sh
```

Run:

```bash
bash -n scripts/verify-phase3.sh
shellcheck scripts/verify-phase3.sh
make phase3-verify
```

Expected final line: `Phase 3 verification passed` after observing replacement backend/MySQL UIDs and retained data.

- [ ] **Step 12: Commit acceptance automation and clarified semantics**

```bash
git add Makefile scripts/verify-phase3.sh docs/superpowers/specs/2026-08-18-phase-3-kubernetes-helm-design.md
git commit -m "test: verify phase 3 recovery and persistence"
```

---

### Task 8: Publish verified Phase 3 operator and learning documentation

**Files:**
- Create: `docs/implementation/phase-3-kubernetes.md`
- Create: `docs/troubleshooting/phase-3-kubernetes.md`
- Create: `docs/runbooks/phase-3-operations.md`
- Modify: `README.md`
- Modify: `deploy/README.md`
- Modify: `docs/architecture.md`

**Interfaces:**
- Consumes: exact commands and observed results from Tasks 1–7.
- Produces: beginner reproduction path, safe operator commands, honest resume evidence, and Phase 4 handoff.

- [ ] **Step 1: Write the implementation record from observed evidence**

Use these exact headings:

```markdown
# Phase 3：Kubernetes 编排与 Helm 标准化部署
## 1. 阶段目标
## 2. 最终架构
## 3. 新增或修改的文件
## 4. 实际执行命令
## 5. 验证结果
## 6. 简历能力映射
## 7. 限制与诚实边界
## 8. 与 Phase 4 的关系
```

Record actual version output, Helm revision, Ready workload counts, replacement Pod UIDs in shortened form, and the observed persistence result from Task 7. Do not paste Secret data, full kubeconfig, or fabricated failures.

- [ ] **Step 2: Write a practical Runbook with safe and destructive operations separated**

Include exact commands for:

```bash
make phase3-cluster-create
make phase3-deploy
make phase3-status
make phase3-logs
make phase3-verify
kubectl get events -n devops-platform --sort-by=.lastTimestamp
PHASE3_BACKEND_POD="$(kubectl get pod -n devops-platform -l app.kubernetes.io/component=backend -o jsonpath='{.items[0].metadata.name}')"
kubectl describe pod -n devops-platform "$PHASE3_BACKEND_POD"
helm history devops-platform -n devops-platform
PHASE3_ROLLBACK_REVISION="$(helm history devops-platform -n devops-platform -o json | jq -r '.[-2].revision')"
helm rollback devops-platform "$PHASE3_ROLLBACK_REVISION" -n devops-platform --wait
make phase3-stop
k3d cluster start devops-platform
```

Place `helm uninstall`, `kubectl delete pvc`, and `k3d cluster delete` in a separate destructive section. Explain the consequence before each command and do not wrap them in a convenient default Make target.

- [ ] **Step 3: Record only real troubleshooting incidents**

Create the troubleshooting document with the standard fields `现象、影响、证据、根本原因、解决办法、验证结果、预防措施`. Add entries only for incidents actually encountered in Tasks 1–7, including the Service/readiness observation-point clarification if it was observed. If no other incident occurred, explicitly state that no additional Phase 3 incident has yet been observed; do not invent one.

- [ ] **Step 4: Promote README from Phase 2 to Phase 3 only after verification**

Update current status, quick start, automated acceptance, request flow, common commands, technology status, route checkmarks, and safety notes. The quick start must be:

```bash
install -m 600 .env.example .env
make phase3-cluster-create
make phase3-deploy
make phase3-verify
```

Keep Phase 4 Jenkins and Phase 5 monitoring explicitly planned, not implemented. State that one replica provides recovery but not zero-downtime high availability, and that deleting the k3d cluster loses local-path storage.

- [ ] **Step 5: Update deployment and architecture boundaries**

`deploy/README.md` must distinguish Compose, application Helm Chart, and separately installed ingress infrastructure. `docs/architecture.md` must show the implemented Phase 3 request path, Service names, health behavior, PVC boundary, and the still-planned Jenkins/monitoring flows.

- [ ] **Step 6: Verify documentation does not overclaim or leak secrets**

Run:

```bash
grep -RInE '生产级高可用|零停机|集群删除.*数据.*保留' README.md docs deploy/README.md
git grep -nEI '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN (OPENSSH|RSA|EC) PRIVATE KEY-----)' -- .
git diff --check
```

Expected: any matching limitation phrases clearly negate the claim; secret scan prints nothing; diff check passes.

- [ ] **Step 7: Commit verified documentation**

```bash
git add README.md deploy/README.md docs/architecture.md docs/implementation/phase-3-kubernetes.md docs/troubleshooting/phase-3-kubernetes.md docs/runbooks/phase-3-operations.md
git commit -m "docs: publish phase 3 kubernetes operations guide"
```

---

### Task 9: Run the cross-phase release gate and independent review

**Files:**
- Create: `docs/reviews/phase-3-independent-review.md`
- Modify: only files required by concrete review findings.

**Interfaces:**
- Consumes: all Phase 3 code, the Phase 1 pytest suite, Phase 2 verifier, and the approved requirement for an independent read-only technical review.
- Produces: a clean, evidence-backed Phase 3 release candidate and written review disposition.

- [ ] **Step 1: Run static and unit regression checks**

```bash
make check
.venv/bin/python -m pytest app/backend/tests -v
shellcheck scripts/*.sh
make phase3-manifests
git diff --check
```

Expected: 14 pytest tests pass, all scripts pass ShellCheck, and manifest checks pass.

- [ ] **Step 2: Run the Phase 2 real-service regression without a port conflict**

Stop but do not delete k3d, run Phase 2, then stop Compose:

```bash
make phase3-stop
make phase2-verify
make phase2-down
```

Expected: Phase 2 verification passes and its MySQL named volume remains.

- [ ] **Step 3: Restore and rerun the complete Phase 3 gate**

```bash
make phase3-cluster-create
make phase3-deploy
make phase3-verify
make phase3-status
```

Expected: the existing cluster/PVC is reused, the Release upgrades successfully, full Phase 3 verification passes, and all workloads finish Ready.

- [ ] **Step 4: Dispatch the approved independent read-only technical review**

Ask a fresh subagent to inspect the Phase 3 diff and running evidence for correctness, security, beginner-sized scope, resume honesty, Kubernetes semantics, Helm lifecycle, destructive operations, and test gaps. The reviewer must not modify files. Save every finding with severity, file/line evidence, disposition, and verification in `docs/reviews/phase-3-independent-review.md`.

- [ ] **Step 5: Resolve review findings through explicit test cycles**

For each accepted finding, first add or run a check that demonstrates it, make the smallest correction, rerun the focused check, then rerun Step 1 and Step 3. Mark rejected or deferred findings with a concrete technical reason and residual risk; do not silently omit them.

- [ ] **Step 6: Commit the review and any verified corrections**

```bash
git add docs/reviews/phase-3-independent-review.md
git add -u
git commit -m "docs: record phase 3 independent review"
```

- [ ] **Step 7: Confirm the final local release state**

```bash
git status --short
git log --oneline --decorate -8
make phase3-verify
```

Expected: clean worktree, an auditable sequence of small commits, and a fresh successful acceptance result. Push to GitHub only after these checks and the user-facing handoff are complete.

---

## Execution Checkpoints

1. **After Task 1:** one pinned K3s node and maintained F5 controller are independently healthy.
2. **After Task 5:** the complete application manifest renders and passes offline safety checks before any business workload is deployed.
3. **After Task 7:** real Ingress CRUD, reconciliation, degraded readiness, recovery, and PVC persistence are automated.
4. **After Task 9:** Phase 1, Phase 2, and Phase 3 all pass their proportional release gates, and an independent reviewer has audited the result.

Do not skip directly to documentation or resume claims when an earlier checkpoint fails.
