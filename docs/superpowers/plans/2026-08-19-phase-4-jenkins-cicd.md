# Phase 4 Jenkins CI/CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible local Jenkins CI/CD pipeline that tests the existing application, builds and verifies Git-SHA-tagged frontend/backend images, pushes them to Docker Hub, deploys them to the existing k3d cluster with Helm, and verifies the real NGINX Ingress path without exposing runtime database credentials.

**Architecture:** A pinned Jenkins LTS JDK 21 controller runs in Docker Desktop on `127.0.0.1:8090`, persists `/var/jenkins_home` in a named volume, and uses the mounted Docker socket for trusted local builds. A repository-root Declarative `Jenkinsfile` delegates detailed work to focused Bash scripts, publishes two public Docker Hub images tagged `git-<sha12>`, and uses a namespace-scoped ServiceAccount kubeconfig to update the existing Phase 3 Helm release. Jenkins never calls `deploy-phase3.sh`, never loads root `.env`, and validates the application through `host.docker.internal:8080`.

**Tech Stack:** Jenkins LTS `2.568.1-jdk21`, Java 21, Docker Desktop/CLI, Git, Bash, Python 3/venv, pytest, ShellCheck, Make, kubectl 1.36.1, Helm 4.2.0, k3d/K3s Kubernetes 1.36.1, F5 NGINX Ingress Controller, Docker Hub, Jenkins Credentials Binding and JUnit.

**Spec:** `docs/superpowers/specs/2026-08-19-phase-4-jenkins-cicd-design.md`

## Global Constraints

- Build only the trusted public repository `main` branch; do not execute untrusted Pull Request Jenkinsfiles.
- Bind Jenkins only to `127.0.0.1:8090`; do not publish port 50000 or expose Jenkins through a public tunnel.
- Use `jenkins/jenkins:2.568.1-jdk21`; never use `latest` for Jenkins or application deployment images.
- Keep the existing k3d cluster `devops-platform`, context `k3d-devops-platform`, application namespace/release `devops-platform`, and Ingress host port `8080`.
- Publish only `zingdzing/devops-web-platform-frontend:git-<sha12>` and `zingdzing/devops-web-platform-backend:git-<sha12>`.
- Preserve all 14 existing pytest tests, Phase 2 behavior, Phase 3 Helm contracts, MySQL StatefulSet, external Secret `devops-platform-db`, and retained PVC.
- Jenkins must not read root `.env`, create/update/delete the database Secret, delete PVCs, uninstall the release, delete the namespace, or prune Docker globally.
- Store only `dockerhub-ci` and `k3d-deployer-kubeconfig` in Jenkins; never commit or log passwords, PATs, tokens, recovery codes, private keys, kubeconfig, `.env`, or rendered Secret data.
- Use a dedicated namespace-scoped ServiceAccount, not the user's admin kubeconfig. Document that Helm Secret storage prevents perfect Secret-level isolation inside one namespace.
- Keep the nine Pipeline stages sequential; use a 30-minute pipeline timeout, disabled concurrent builds, timestamps, and 20-build retention.
- Use Helm transaction failure rollback, but do not automatically issue an additional rollback after a post-deploy smoke-test failure.
- The user personally creates the Jenkins password and Docker Hub PAT and enters them in the UI; agents must never request their values.
- Record only failures actually observed during implementation. README may claim Phase 4 only after the complete acceptance gate passes.

---

## File Map

**Create**

- `Jenkinsfile` — Declarative orchestration, stage boundaries, credentials scope, reports, diagnostics, and cleanup.
- `deploy/jenkins/Dockerfile` — pinned Jenkins controller plus required CLI tools and plugins.
- `deploy/jenkins/compose.yaml` — loopback port, named home volume, Docker socket, and host gateway.
- `deploy/jenkins/entrypoint.sh` — grants the Jenkins user socket-group access and then drops root.
- `deploy/jenkins/plugins.txt` — minimal Pipeline/Git/Credentials/JUnit/Stage View plugin set.
- `deploy/kubernetes/jenkins-rbac.yaml` — `jenkins-deployer` ServiceAccount, token Secret, namespace Role, and RoleBinding.
- `scripts/create-phase4-kubeconfig.sh` — creates a temporary, permission-600, host-reachable kubeconfig without printing its token.
- `scripts/ci/common.sh` — shared constants, logging, required-variable and tag validation.
- `scripts/ci/unit-test.sh` — isolated venv, dependency install, pytest JUnit output.
- `scripts/ci/quality-check.sh` — Git, shell, Helm, init SQL, secret-shape, and floating-tag checks.
- `scripts/ci/build-images.sh` — two Git-SHA image builds with OCI metadata and report output.
- `scripts/ci/verify-images.sh` — revision, non-root, Nginx, Flask/Gunicorn, and production-dependency checks.
- `scripts/ci/deploy.sh` — protected Helm image-only upgrade and rollout/image verification.
- `scripts/ci/smoke-test.sh` — bounded, read-only real-Ingress health/page/API checks.
- `scripts/ci/collect-diagnostics.sh` — secret-safe Kubernetes evidence collection.
- `scripts/check-phase4-contract.sh` — offline static contract for Jenkins/CI files.
- `scripts/verify-phase4.sh` — live Jenkins, registry, rollout, ingress, persistence, and restart acceptance.
- `docs/implementation/phase-4-jenkins-cicd.md` — verified commands, versions, output, and resume mapping.
- `docs/troubleshooting/phase-4-jenkins-cicd.md` — only incidents actually observed.
- `docs/runbooks/phase-4-jenkins-operations.md` — start/stop, credentials rotation, diagnostics, and manual rollback.
- `docs/reviews/phase-4-independent-review.md` — final review findings and dispositions.

**Modify**

- `.gitignore` — ignore generated Jenkins/kubeconfig/reports without hiding source configuration.
- `Makefile` — Phase 4 build/start/log/stop/contract/kubeconfig/verify targets.
- `app/frontend/src/index.html` — publish the visible Phase 4 marker only at the acceptance task.
- `README.md` — publish verified Phase 4 quick start and architecture only after acceptance.
- `deploy/README.md` — document Phase 3 manual deployment versus Phase 4 CI deployment.
- `docs/architecture.md` — add the verified GitHub/Jenkins/Docker Hub delivery path.

## Stable Interfaces

All CI scripts run from repository root and use strict Bash mode. `scripts/ci/common.sh` exports these names:

```bash
readonly CI_NAMESPACE='devops-platform'
readonly CI_RELEASE='devops-platform'
readonly CI_CHART_DIR='deploy/helm/devops-web-platform'
readonly CI_FRONTEND_DEPLOYMENT='devops-platform-devops-web-platform-frontend'
readonly CI_BACKEND_DEPLOYMENT='devops-platform-devops-web-platform-backend'
readonly CI_MYSQL_STATEFULSET='devops-platform-devops-web-platform-mysql'
readonly CI_DATABASE_SECRET='devops-platform-db'
readonly CI_FRONTEND_REPOSITORY='zingdzing/devops-web-platform-frontend'
readonly CI_BACKEND_REPOSITORY='zingdzing/devops-web-platform-backend'
```

Build/deploy scripts consume `IMAGE_TAG=git-[0-9a-f]{12}`. Kubernetes scripts consume `KUBECONFIG` as a Jenkins Secret File path. `smoke-test.sh` defaults `CI_BASE_URL` to `http://host.docker.internal:8080`. No script sources `.env`.

---

### Task 1: Promote the verified Phase 3 baseline and create the Phase 4 worktree

**Files:**
- Verify: all tracked Phase 1–3 files
- Commit: `docs/superpowers/specs/2026-08-19-phase-4-jenkins-cicd-design.md`
- Commit: `docs/superpowers/plans/2026-08-19-phase-4-jenkins-cicd.md`

**Interfaces:**
- Consumes: clean branch `phase3-kubernetes-helm` at or after `f4c4f31`; local `main` at `34a239f`; public origin.
- Produces: `main` fast-forwarded through verified Phase 3 and planning docs, then isolated branch/worktree `phase4-jenkins-cicd` at `/home/zing/projects/devops-web-platform-phase4`.

- [ ] **Step 1: Verify the Phase 3 source worktree is clean except for these two planning documents**

```bash
cd /home/zing/projects/devops-web-platform-phase3
git status --short --branch
git diff --check
```

Expected: branch is `phase3-kubernetes-helm`; only the Phase 4 spec and plan are untracked/modified; `git diff --check` exits 0.

- [ ] **Step 2: Re-run the non-destructive baseline gate**

```bash
make phase1-test
make phase3-manifests
bash -n scripts/*.sh
shellcheck scripts/*.sh
```

Expected: 14 pytest tests pass; manifests, Bash syntax, and ShellCheck pass. Do not run destructive cleanup.

- [ ] **Step 3: Commit the approved Phase 4 design and plan**

```bash
git add docs/superpowers/specs/2026-08-19-phase-4-jenkins-cicd-design.md \
  docs/superpowers/plans/2026-08-19-phase-4-jenkins-cicd.md
git commit -m "docs: design phase 4 jenkins cicd"
```

Expected: one documentation-only commit.

- [ ] **Step 4: Fast-forward main and push the completed Phase 3 checkpoint**

```bash
cd /home/zing/projects/devops-web-platform
git merge --ff-only phase3-kubernetes-helm
git push origin main
git status --short --branch
```

Expected: local and origin `main` point to the planning commit and the worktree is clean. If fast-forward is impossible, stop; never force push or reset.

- [ ] **Step 5: Create the isolated implementation worktree**

```bash
git worktree add -b phase4-jenkins-cicd \
  /home/zing/projects/devops-web-platform-phase4 main
cd /home/zing/projects/devops-web-platform-phase4
git status --short --branch
```

Expected: clean `phase4-jenkins-cicd` branch.

---

### Task 2: Build the persistent Jenkins controller image

**Files:**
- Create: `deploy/jenkins/Dockerfile`
- Create: `deploy/jenkins/compose.yaml`
- Create: `deploy/jenkins/entrypoint.sh`
- Create: `deploy/jenkins/plugins.txt`
- Modify: `.gitignore`
- Modify: `Makefile`

**Interfaces:**
- Consumes: Docker Desktop, loopback port 8090, Docker socket, internet access during image build.
- Produces: container `devops-platform-jenkins`, image `devops-platform-jenkins:2.568.1`, volume `devops-platform-jenkins-home`, URL `http://localhost:8090`, and all stable CLI tools.

- [ ] **Step 1: Add a failing Jenkins infrastructure contract**

Create the first section of `scripts/check-phase4-contract.sh` with strict mode and assertions that the four `deploy/jenkins` files exist, Compose binds `127.0.0.1:8090:8080`, uses a named `/var/jenkins_home` volume, mounts `/var/run/docker.sock`, and does not publish `50000`.

Run:

```bash
bash scripts/check-phase4-contract.sh
```

Expected: FAIL with `deploy/jenkins/Dockerfile is missing`.

- [ ] **Step 2: Define the minimal plugin set**

Create `deploy/jenkins/plugins.txt`:

```text
workflow-aggregator
git
credentials-binding
junit
timestamper
pipeline-stage-view
ws-cleanup
```

- [ ] **Step 3: Create the custom Jenkins image**

Use `FROM jenkins/jenkins:2.568.1-jdk21`; switch to root; install `ca-certificates curl git jq make shellcheck python3 python3-venv python3-pip gosu`; add Docker's official Debian repository and install `docker-ce-cli`; download kubectl `v1.36.1` and verify its published SHA256; download Helm `v4.2.0` and verify its published SHA256; copy `plugins.txt` and run `jenkins-plugin-cli -f`; copy the entrypoint; then return to the custom root entrypoint. Do not install Blue Ocean or Docker Agent plugins.

The final lines must be:

```dockerfile
COPY --chown=root:root entrypoint.sh /usr/local/bin/devops-jenkins-entrypoint
RUN chmod 0755 /usr/local/bin/devops-jenkins-entrypoint
USER root
ENTRYPOINT ["/usr/local/bin/devops-jenkins-entrypoint"]
```

- [ ] **Step 4: Drop privileges after matching the Docker socket group**

Create `deploy/jenkins/entrypoint.sh` with strict mode. It must verify the socket exists, read `stat -c '%g' /var/run/docker.sock`, create/reuse a group for that GID, add `jenkins` to it, and finish with:

```bash
exec gosu jenkins /usr/bin/tini -- /usr/local/bin/jenkins.sh
```

It must not chmod the host socket and must not run Jenkins itself as root.

- [ ] **Step 5: Define the Compose boundary**

Create `deploy/jenkins/compose.yaml` with one service, build context `.`, image `devops-platform-jenkins:2.568.1`, container name `devops-platform-jenkins`, restart `unless-stopped`, port `127.0.0.1:8090:8080`, socket mount, named home volume, and:

```yaml
extra_hosts:
  - host.docker.internal:host-gateway
```

Do not publish `50000`.

- [ ] **Step 6: Add safe Make targets**

Add `phase4-jenkins-build`, `phase4-jenkins-up`, `phase4-jenkins-logs`, and `phase4-jenkins-stop`. Stop must run `docker compose stop`, not `down --volumes`.

- [ ] **Step 7: Validate and start Jenkins**

```bash
bash -n deploy/jenkins/entrypoint.sh scripts/check-phase4-contract.sh
shellcheck deploy/jenkins/entrypoint.sh scripts/check-phase4-contract.sh
docker compose -f deploy/jenkins/compose.yaml config --quiet
make phase4-jenkins-build
make phase4-jenkins-up
docker exec devops-platform-jenkins java -version
docker exec devops-platform-jenkins docker version --format '{{.Client.Version}}'
docker exec devops-platform-jenkins kubectl version --client
docker exec devops-platform-jenkins helm version
docker exec devops-platform-jenkins shellcheck --version
curl --head --retry 30 --retry-delay 2 http://127.0.0.1:8090/login
```

Expected: tools report pinned families, Docker Server is reachable, and Jenkins returns an HTTP login/setup response.

- [ ] **Step 8: Commit the Jenkins runtime**

```bash
git add deploy/jenkins .gitignore Makefile scripts/check-phase4-contract.sh
git commit -m "feat: add persistent phase 4 jenkins runtime"
```

---

### Task 3: Create the namespace-scoped deployment identity

**Files:**
- Create: `deploy/kubernetes/jenkins-rbac.yaml`
- Create: `scripts/create-phase4-kubeconfig.sh`
- Modify: `scripts/check-phase4-contract.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: existing context `k3d-devops-platform`, namespace `devops-platform`, host-reachable k3d API port.
- Produces: ServiceAccount `jenkins-deployer`, token Secret `jenkins-deployer-token`, Role/RoleBinding `jenkins-deployer`, and temporary `/tmp/devops-platform-jenkins-kubeconfig` mode 600.

- [ ] **Step 1: Extend the contract and verify it fails**

Require the RBAC file to contain only namespaced `Role`/`RoleBinding`, forbid `ClusterRole`/`cluster-admin`, and require the generator script to refuse a non-`k3d-devops-platform` context.

Run `bash scripts/check-phase4-contract.sh` and expect failure because the RBAC file is absent.

- [ ] **Step 2: Define ServiceAccount, token Secret, Role, and RoleBinding**

Create four YAML documents in `deploy/kubernetes/jenkins-rbac.yaml`. Use namespace `devops-platform`; annotate the `kubernetes.io/service-account-token` Secret with `kubernetes.io/service-account.name: jenkins-deployer`; grant only namespaced CRUD/get/list/watch needed by Helm for ConfigMaps, release Secrets, Services, Pods, PVCs, Deployments, ReplicaSets, StatefulSets and Ingresses, plus read-only Events. Do not include Namespace, Node, PV, RBAC mutation, CRD or cluster-scoped permissions.

- [ ] **Step 3: Write the safe kubeconfig generator**

The script must:

1. Check `kubectl`, `docker`, `jq`, `mktemp`, and `stat`.
2. Require current context `k3d-devops-platform` and namespace/release/DB Secret/PVC existence.
3. Apply only `deploy/kubernetes/jenkins-rbac.yaml`.
4. Wait for the generated token data without printing it.
5. read the cluster CA from the current kubeconfig.
6. convert the k3d API server endpoint to `https://host.docker.internal:<published-port>`.
7. write `/tmp/devops-platform-jenkins-kubeconfig` under `umask 077`.
8. validate it from inside the Jenkins container with `kubectl auth can-i` and a Pod list.
9. print only the file path and upload/delete instructions.

It must never print the token, CA data, or complete kubeconfig.

- [ ] **Step 4: Add and run the generator target**

```make
phase4-kubeconfig:
	@bash scripts/create-phase4-kubeconfig.sh
```

Run:

```bash
bash -n scripts/create-phase4-kubeconfig.sh
shellcheck scripts/create-phase4-kubeconfig.sh
make phase4-kubeconfig
stat -c '%a %n' /tmp/devops-platform-jenkins-kubeconfig
```

Expected: `600`; Jenkins container can list target Pods; `kubectl auth can-i get nodes` with this kubeconfig says `no`.

- [ ] **Step 5: Commit the deployment identity**

```bash
git add deploy/kubernetes/jenkins-rbac.yaml scripts/create-phase4-kubeconfig.sh \
  scripts/check-phase4-contract.sh Makefile
git commit -m "feat: add scoped jenkins deployment identity"
```

---

### Task 4: Implement shared CI, unit-test, and quality gates

**Files:**
- Create: `scripts/ci/common.sh`
- Create: `scripts/ci/unit-test.sh`
- Create: `scripts/ci/quality-check.sh`
- Modify: `scripts/check-phase4-contract.sh`

**Interfaces:**
- Consumes: repository root, tracked source, existing test/Chart files.
- Produces: validated `IMAGE_TAG`, `reports/pytest.xml`, and a passing offline source/manifest security gate.

- [ ] **Step 1: Add failing CI script contracts**

Require every `scripts/ci/*.sh` file, strict mode, no `.env` source, no `kubectl get secret ... -o yaml`, and no destructive commands from the Global Constraints. Expect failure while scripts are missing.

- [ ] **Step 2: Implement shared constants and validation**

Create `common.sh` with the Stable Interfaces constants plus:

```bash
ci_fail() { printf '[phase4-ci] ERROR: %s\n' "$1" >&2; exit 1; }
ci_log() { printf '[phase4-ci] %s\n' "$1"; }
ci_require_command() { command -v "$1" >/dev/null 2>&1 || ci_fail "$1 is missing"; }
ci_require_variable() { [[ -n "${!1:-}" ]] || ci_fail "$1 is empty"; }
ci_validate_image_tag() { [[ "$1" =~ ^git-[0-9a-f]{12}$ ]] || ci_fail 'IMAGE_TAG must match git-<12 lowercase hex>'; }
```

- [ ] **Step 3: Implement the unit-test gate**

`unit-test.sh` must remove/recreate `.venv-ci`, install `app/backend/requirements-dev.txt`, create `reports`, and run:

```bash
.venv-ci/bin/python -m pytest app/backend/tests -v \
  --junitxml=reports/pytest.xml
```

Do not use the developer `.venv`.

- [ ] **Step 4: Implement the quality gate**

`quality-check.sh` must run `git diff --check`, `bash -n` and ShellCheck on all tracked `.sh` files plus the Jenkins entrypoint, `make phase3-manifests`, `cmp app/database/init.sql` with Chart `files/init.sql`, tracked secret-shaped filename rejection, known GitHub token/private-key signature scan, and reject `:latest` from deploy/Jenkins/CI configuration.

- [ ] **Step 5: Run the gates**

```bash
bash scripts/ci/unit-test.sh
bash scripts/ci/quality-check.sh
test -s reports/pytest.xml
grep -F 'tests="14"' reports/pytest.xml
```

Expected: 14 tests pass and all quality checks pass.

- [ ] **Step 6: Commit test and quality scripts**

```bash
git add scripts/ci/common.sh scripts/ci/unit-test.sh scripts/ci/quality-check.sh \
  scripts/check-phase4-contract.sh
git commit -m "test: add phase 4 unit and quality gates"
```

---

### Task 5: Implement image build and verification

**Files:**
- Create: `scripts/ci/build-images.sh`
- Create: `scripts/ci/verify-images.sh`
- Modify: `scripts/check-phase4-contract.sh`

**Interfaces:**
- Consumes: `IMAGE_TAG`, optional `GIT_COMMIT_FULL`, optional `BUILD_NUMBER`, Docker Engine.
- Produces: two local `zingdzing/...:${IMAGE_TAG}` images with OCI labels and `reports/images.txt`.

- [ ] **Step 1: Add failing image-script contracts**

Require the repository constants, tag validator, OCI revision label, two Docker builds, non-root checks, `nginx -t`, backend import check, and pytest absence check. Expect failure while scripts are absent.

- [ ] **Step 2: Implement deterministic build metadata**

`build-images.sh` must derive full SHA from `git rev-parse HEAD` when not supplied, verify its first 12 characters match `IMAGE_TAG`, check Docker, create `reports`, and build both contexts with:

```bash
--label org.opencontainers.image.source=https://github.com/zingdzing/devops-web-platform
--label org.opencontainers.image.revision="$GIT_COMMIT_FULL"
--label io.jenkins.build.number="${BUILD_NUMBER:-local}"
```

Write image names, IDs and revisions to `reports/images.txt`; never write Docker config or credentials.

- [ ] **Step 3: Implement image verification**

`verify-images.sh` must compare each revision label to Git HEAD; assert `docker run --rm --entrypoint id IMAGE -u` is not `0`; run frontend `nginx -t` with an `--add-host backend:127.0.0.1` mapping; run backend `python -c 'from app import create_app; assert create_app'`; and assert `python -m pytest --version` fails inside the backend production image.

- [ ] **Step 4: Run with a real local SHA tag**

```bash
export IMAGE_TAG="git-$(git rev-parse --short=12 HEAD)"
bash scripts/ci/build-images.sh
bash scripts/ci/verify-images.sh
cat reports/images.txt
```

Expected: both images pass; report contains no credentials.

- [ ] **Step 5: Commit image delivery gates**

```bash
git add scripts/ci/build-images.sh scripts/ci/verify-images.sh \
  scripts/check-phase4-contract.sh
git commit -m "feat: build and verify git tagged images"
```

---

### Task 6: Implement protected deploy, smoke, and diagnostics scripts

**Files:**
- Create: `scripts/ci/deploy.sh`
- Create: `scripts/ci/smoke-test.sh`
- Create: `scripts/ci/collect-diagnostics.sh`
- Modify: `scripts/check-phase4-contract.sh`

**Interfaces:**
- Consumes: valid `IMAGE_TAG`, Jenkins `KUBECONFIG`, existing release/Secret/PVC, public Docker Hub images.
- Produces: Helm upgrade with image-only overrides, verified rollouts/actual images, read-only Ingress smoke result, and `reports/kubernetes-diagnostics.txt` on failure.

- [ ] **Step 1: Add failing deploy safety contracts**

Require `--set-string images.frontend.repository`, frontend tag, backend repository, backend tag, `--rollback-on-failure`, bounded wait, `/api/items`, and actual image comparison. Forbid `kubectl create secret`, `.env`, PVC/namespace deletion, `helm uninstall`, and automatic `helm rollback` in CI scripts.

- [ ] **Step 2: Implement the protected Helm deployment**

`deploy.sh` must validate tag/kubeconfig, require the kubeconfig current context name `jenkins-deployer@devops-platform`, confirm namespace, release, external DB Secret metadata and at least one Bound MySQL PVC, then run:

```bash
helm upgrade --install "$CI_RELEASE" "$CI_CHART_DIR" \
  --kubeconfig "$KUBECONFIG" --namespace "$CI_NAMESPACE" \
  --set-string images.frontend.repository="$CI_FRONTEND_REPOSITORY" \
  --set-string images.frontend.tag="$IMAGE_TAG" \
  --set-string images.backend.repository="$CI_BACKEND_REPOSITORY" \
  --set-string images.backend.tag="$IMAGE_TAG" \
  --rollback-on-failure --wait=watcher --timeout 5m
```

Then use `kubectl rollout status` for both Deployments, require MySQL ready replicas `1`, and compare both Pod image fields exactly to `${repository}:${IMAGE_TAG}`.

- [ ] **Step 3: Implement bounded read-only smoke checks**

`smoke-test.sh` must poll `/readyz` up to 30 times with 2-second intervals, then require 200 for `/healthz` and `/readyz`, grep `DEVOPS WEB PLATFORM · PHASE 4` from `/`, and parse `/api/items` with `python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin), list)'`. Every curl uses `Host: localhost`; no POST/PUT/DELETE is allowed.

- [ ] **Step 4: Implement secret-safe diagnostics**

`collect-diagnostics.sh` writes only Git/build metadata, `helm status`, `kubectl get deployment,statefulset,pod,svc,ingress,pvc`, recent Events, and tail logs from frontend/backend. It must never call `kubectl get secret -o yaml/json`, `env`, `printenv`, or `helm get values --all`. Diagnostic failures are nonfatal to the original build result.

- [ ] **Step 5: Validate offline contracts and shell quality**

```bash
bash scripts/check-phase4-contract.sh
bash -n scripts/ci/*.sh
shellcheck scripts/ci/*.sh
```

Expected: pass. Do not run deploy until remote images and Jenkins credentials exist.

- [ ] **Step 6: Commit delivery and diagnostics scripts**

```bash
git add scripts/ci/deploy.sh scripts/ci/smoke-test.sh \
  scripts/ci/collect-diagnostics.sh scripts/check-phase4-contract.sh
git commit -m "feat: add protected helm delivery scripts"
```

---

### Task 7: Orchestrate the nine-stage Declarative Jenkinsfile

**Files:**
- Create: `Jenkinsfile`
- Modify: `scripts/check-phase4-contract.sh`

**Interfaces:**
- Consumes: all `scripts/ci` interfaces; Jenkins Credentials `dockerhub-ci` and `k3d-deployer-kubeconfig`.
- Produces: sequential nine-stage Pipeline, JUnit and report artifacts, safe logout/diagnostics/local-image cleanup.

- [ ] **Step 1: Extend the contract for all stage names and global options**

Require exactly these stage labels in order: `Checkout`, `Unit Test`, `Quality Check`, `Build Images`, `Image Verification`, `Push Images`, `Deploy`, `Rollout Verification`, `Smoke Test`. Require timeout 30 minutes, disabled concurrency, timestamps, 20-build retention, `pollSCM`, both credential IDs, JUnit, artifact archive, and diagnostics. Expect failure before creating `Jenkinsfile`.

- [ ] **Step 2: Create the Pipeline header and checkout metadata**

Use:

```groovy
pipeline {
  agent any
  options {
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    skipDefaultCheckout(true)
  }
  triggers { pollSCM('H/5 * * * *') }
```

Checkout runs `checkout scm`, rejects a non-main `GIT_BRANCH`, sets full/short SHA and `IMAGE_TAG`, and updates `currentBuild.displayName` without printing secrets.

- [ ] **Step 3: Wire the five pre-publication stages**

Call `unit-test.sh`, publish `reports/pytest.xml` in a stage `post { always { ... } }`, then call quality, build and image verification scripts. Use `retry(2)` only around dependency/test setup if the observed failure is network-related; never retry failed assertions.

- [ ] **Step 4: Scope Docker Hub credentials only to Push Images**

Use `withCredentials(usernamePassword(...))`, a single-quoted shell block, `set +x`, `printf` into `docker login --password-stdin`, two pushes wrapped in `retry(3)`, and `docker logout` in `finally`. Do not bind credentials in the global environment.

- [ ] **Step 5: Scope kubeconfig only to deploy/rollout/smoke**

Bind Secret File `k3d-deployer-kubeconfig` to `KUBECONFIG` around the three stages. `Deploy` calls `deploy.sh`; `Rollout Verification` runs explicit status/image assertions or a `--verify-only` interface defined in `deploy.sh`; `Smoke Test` calls `smoke-test.sh`.

- [ ] **Step 6: Add safe post behavior**

On failure, call diagnostics only when `KUBECONFIG` can be rebound. Always archive `reports/**/*` with `allowEmptyArchive: true`; delete `.venv-ci`; remove only the two `${IMAGE_TAG}` local image references nonfatally; never prune Docker or delete Kubernetes resources.

- [ ] **Step 7: Validate the Jenkinsfile contract**

```bash
bash scripts/check-phase4-contract.sh
git diff --check
```

Expected: all nine stages and safety contracts pass.

- [ ] **Step 8: Commit the Pipeline**

```bash
git add Jenkinsfile scripts/check-phase4-contract.sh
git commit -m "feat: orchestrate phase 4 jenkins pipeline"
```

---

### Task 8: Complete the user-owned Jenkins and Docker Hub setup checkpoint

**Files:**
- Create: `docs/runbooks/phase-4-jenkins-operations.md`
- Modify: `deploy/README.md`

**Interfaces:**
- Consumes: running Jenkins, two public Docker Hub repositories, user-created Jenkins password and Read & Write PAT, generated kubeconfig.
- Produces: Jenkins folder/job `devops-web-platform`, credentials with exact IDs, SCM fixed to public `main`, and no disclosed secret values.

- [ ] **Step 1: Document and perform Jenkins first-login setup**

Retrieve the one-time unlock value locally with:

```bash
docker exec devops-platform-jenkins \
  cat /var/jenkins_home/secrets/initialAdminPassword
```

The user creates a unique administrator password. Do not record it. Confirm `http://localhost:8090` login and installed plugins.

- [ ] **Step 2: Have the user create the two public Docker Hub repositories**

Exact names:

```text
zingdzing/devops-web-platform-frontend
zingdzing/devops-web-platform-backend
```

No repository password is created.

- [ ] **Step 3: Have the user create and store the Docker PAT**

Create PAT label `jenkins-devops-web-platform` with Read & Write and a finite expiry. Add Jenkins Username with password Credential ID `dockerhub-ci`; username is `zingdzing`; password field is the PAT. The user must not send or screenshot it.

- [ ] **Step 4: Upload and remove the generated kubeconfig**

Add Secret file Credential ID `k3d-deployer-kubeconfig` from `/tmp/devops-platform-jenkins-kubeconfig`, test the Pipeline can use it, then remove only that temporary file:

```bash
rm -f -- /tmp/devops-platform-jenkins-kubeconfig
```

This explicit removal is allowed after successful upload; never remove personal kubeconfig.

- [ ] **Step 5: Create the Pipeline job**

Create Folder `devops-web-platform`, then Pipeline `main`; choose “Pipeline script from SCM”, Git URL `https://github.com/zingdzing/devops-web-platform.git`, no Git credentials, branch `*/main`, script path `Jenkinsfile`, and lightweight checkout where supported.

- [ ] **Step 6: Write the operations runbook and commit it**

Document safe start/stop/logs, credential rotation without values, PAT revoke/recreate, ServiceAccount token revoke/recreate, Jenkins password recovery boundary, `helm history`, manual `helm rollback devops-platform <revision> -n devops-platform --wait`, data-protection warnings, Docker Socket risk, and Helm/database Secret RBAC limitation.

```bash
git add docs/runbooks/phase-4-jenkins-operations.md deploy/README.md
git commit -m "docs: add phase 4 jenkins operations runbook"
```

---

### Task 9: Run manual and automatic end-to-end acceptance

**Files:**
- Create: `scripts/verify-phase4.sh`
- Modify: `Makefile`
- Modify: `app/frontend/src/index.html`

**Interfaces:**
- Consumes: configured Jenkins job/credentials, running k3d, Docker Hub, application data marker.
- Produces: successful Build Now run, successful Poll SCM run, exact image/Helm/Ingress evidence, persistence proof, and Jenkins restart proof.

- [ ] **Step 1: Update the visible page marker before the release build**

Change only the phase eyebrow/capability copy to `DEVOPS WEB PLATFORM · PHASE 4` and mention Jenkins CI/CD without changing CRUD behavior. Run the 14 tests and Phase 3 manifest gate.

- [ ] **Step 2: Create a persistence marker through the existing UI**

Create one task titled `Phase 4 pipeline persistence` with a description stating it must survive deployment. Record only its numeric ID in a temporary shell variable/file under `/tmp`, not in Git.

- [ ] **Step 3: Push the implementation branch for review, then fast-forward main**

```bash
git add app/frontend/src/index.html
git commit -m "feat: publish phase 4 pipeline marker"
git push -u origin phase4-jenkins-cicd
git log --oneline main..phase4-jenkins-cicd
```

After review gates pass, fast-forward `main` and push; never force push.

- [ ] **Step 4: Run the first manual Jenkins build**

Click `Build Now`. Require all nine stages green, 14 tests in Jenkins, two Docker Hub tags using the build SHA, a new Helm Revision, both Deployments using exact tags, and all Pods Ready.

- [ ] **Step 5: Implement the independent live verifier**

`verify-phase4.sh` must check Jenkins HTTP availability, home volume and tool commands, Docker Hub image manifests for the deployed tag, Helm deployed status, actual Pod images, all three workload readiness states, `/healthz`, `/readyz`, Phase 4 page marker, `/api/items` JSON, and the persistence marker ID. It must restart only the Jenkins container, wait for login, and confirm the Job API exists after restart. It must not delete any application resource or read secret values.

- [ ] **Step 6: Run the acceptance target**

```make
phase4-contract:
	@bash scripts/check-phase4-contract.sh

phase4-verify:
	@bash scripts/verify-phase4.sh
```

Run:

```bash
make phase4-contract
make phase4-verify
```

Expected: contracts, registry, deployment, real Ingress, persistence, and Jenkins restart all pass.

- [ ] **Step 7: Verify Poll SCM with one normal main commit**

Push a documentation-only evidence commit after manual success, wait at least one polling interval, and confirm Jenkins automatically starts a new build for that SHA. Do not create a public webhook.

- [ ] **Step 8: Commit the acceptance automation**

```bash
git add scripts/verify-phase4.sh Makefile
git commit -m "test: verify phase 4 cicd delivery"
```

---

### Task 10: Publish evidence, troubleshooting, and resume-ready documentation

**Files:**
- Create: `docs/implementation/phase-4-jenkins-cicd.md`
- Create: `docs/troubleshooting/phase-4-jenkins-cicd.md`
- Create: `docs/reviews/phase-4-independent-review.md`
- Modify: `README.md`
- Modify: `docs/architecture.md`
- Modify: `deploy/README.md`

**Interfaces:**
- Consumes: actual successful build number/SHA, plugin/tool versions, Docker Hub tags, Helm Revision, validation output, and real incidents.
- Produces: reproducible Phase 4 handoff and claims limited to verified facts.

- [ ] **Step 1: Record implementation evidence**

Document exact Jenkins core/tool versions, nine stages, 14-test result, both image addresses, deployed SHA, Helm Revision, workload states, Ingress checks, persistence marker result, Jenkins restart result, and Poll SCM evidence. Do not paste credential values or raw kubeconfig.

- [ ] **Step 2: Record only real troubleshooting incidents**

For each observed failure, capture symptom, safe evidence, root cause, correction, and prevention. If no incident occurred for a category, omit it; do not manufacture examples as incidents.

- [ ] **Step 3: Update architecture and README**

Mark Phase 4 complete only now. Add `GitHub -> Jenkins -> Docker Hub -> Helm -> k3d` flow, quick start links, credential boundary, Docker Socket/long-token/Helm Secret limitations, and keep Phase 5 monitoring explicitly planned rather than implemented.

- [ ] **Step 4: Perform an independent technical review**

Review scope: correctness, pipeline order, credential scope, destructive-command absence, database/PVC safety, failure behavior, reproducibility, beginner complexity, resume honesty, and clean Git state. Record every finding and disposition in `docs/reviews/phase-4-independent-review.md`; fix P0/P1 and justified P2 findings before release.

- [ ] **Step 5: Run the final release gate from a clean tree**

```bash
make phase1-test
make phase3-manifests
make phase4-contract
make phase4-verify
git diff --check
git status --short
```

Expected: all gates pass and status is clean after the documentation commit.

- [ ] **Step 6: Commit and push the verified Phase 4 release**

```bash
git add README.md deploy/README.md docs/architecture.md \
  docs/implementation/phase-4-jenkins-cicd.md \
  docs/troubleshooting/phase-4-jenkins-cicd.md \
  docs/reviews/phase-4-independent-review.md
git commit -m "docs: publish verified phase 4 cicd workflow"
git push origin main
```

Expected: GitHub main contains only verified claims and no sensitive files.

---

## Self-Review Checklist

- Spec coverage: Tasks 2–3 cover architecture and credentials; Tasks 4–7 cover all nine Pipeline stages; Task 8 covers user-owned secrets; Task 9 covers functional, persistence, restart, and Poll SCM acceptance; Task 10 covers evidence, review, and resume claims.
- Destructive boundary: no task deletes the database Secret, PVC, namespace, Helm release, Jenkins volume, or Docker global cache. The only explicit `rm` targets the generated `/tmp/devops-platform-jenkins-kubeconfig` after upload.
- Secret boundary: no code consumes `.env`; Docker PAT and kubeconfig exist only in Jenkins Credentials; diagnostic commands never dump Secret data.
- API consistency: all smoke and persistence checks use the implemented `/api/items` endpoint.
- Type/name consistency: `IMAGE_TAG`, repository names, Credential IDs, Kubernetes resource names, release, namespace, context, and ports match the Stable Interfaces and spec.
- Scope: no monitoring, dynamic agents, public webhook, multi-environment deployment, or automatic post-smoke rollback was added.
