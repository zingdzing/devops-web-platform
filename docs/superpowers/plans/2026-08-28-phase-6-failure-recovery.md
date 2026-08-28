# Phase 6 Failure Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 DevOps Web Platform 增加一个默认关闭、人工批准、能够真实触发错误镜像发布并验证 Helm 自动回滚的 Jenkins 故障演练闭环。

**Architecture:** Jenkins 在现有九个正常阶段之后按参数进入独立 `Failure Drill` 阶段；演练脚本记录健康基线和持久化标记，用不存在的 backend 镜像标签触发 Kubernetes 拉取失败，并依赖 Helm `--rollback-on-failure` 恢复。脚本验证应用、MySQL PVC、监控 Target 和工作负载，归档非敏感证据；成功完成演练后由 Jenkins 主动把本次构建标为预期红色，再以一次正常绿色构建证明交付链路恢复。

**Tech Stack:** Jenkins 2.568 Declarative Pipeline、Bash、ShellCheck、Helm 4、Kubernetes/k3d、kubectl、Docker Hub、Flask API、MySQL StatefulSet/PVC、Prometheus HTTP API、jq、curl、Make。

**Spec:** `docs/superpowers/specs/2026-08-28-phase-6-failure-recovery-design.md`

## Global Constraints

- 故障演练只在本机 WSL2、Docker Desktop、k3d 非生产集群执行。
- Jenkins 参数固定为 `RUN_FAILURE_DRILL`，类型为 Boolean，默认值必须为 `false`。
- SCM 轮询与普通构建不得进入故障演练；手动设置参数为 `true` 后还需 `zing` 在 Jenkins `input` 步骤批准。
- 故障镜像固定使用 `zingzin/devops-web-platform-backend:failure-drill-${BUILD_NUMBER}-does-not-exist`，不得构建或推送该标签。
- Helm 故障升级继续使用 `--rollback-on-failure --wait=watcher --timeout 5m`；不得用删除 Release、Namespace、Secret 或 PVC 代替回滚。
- 不修改数据库密码，不破坏 MySQL 数据，不停止 Docker Desktop、WSL 或整个 k3d 集群。
- 演练逻辑放在 `scripts/phase6/`，正常发布逻辑继续留在 `scripts/ci/`。
- 演练脚本恢复成功后返回 `0`；Jenkins 随后主动抛出 `EXPECTED_DRILL_FAILURE`，把演练构建设为预期红色。
- 演练脚本恢复失败时返回非零并写入 `RECOVERY_FAILURE`；不得只根据 Jenkins 颜色判断结论。
- 报告使用显式白名单，不归档 kubeconfig、Token、密码、Secret 内容、Docker 配置或完整环境变量。
- Prometheus、Grafana 与 Alertmanager 保持 Phase 5 的单实例精简配置，不重装监控栈。
- Jenkins 在 `monitoring` Namespace 只获得查看 Pods/Services/Endpoints 与建立临时 Pod port-forward 的权限；必须继续拒绝读取 Secret、修改资源和访问集群级 Node。
- 每次完成声明必须有合同检查、回归测试和真实环境证据。

---

## File Responsibility Map

| File | Responsibility |
|---|---|
| `scripts/check-phase6-contract.sh` | 静态检查参数、安全边界、文件接口、报告白名单和禁止命令 |
| `scripts/phase6/common.sh` | 提供 Phase 6 常量、日志、命令/变量校验、API 与 Kubernetes 查询函数 |
| `scripts/phase6/failure-drill.sh` | 在 Jenkins 中编排基线、错误镜像发布、诊断、回滚检查和恢复报告 |
| `scripts/verify-phase6.sh` | 使用本机管理员 context 对恢复后的应用、数据、PVC 与监控做最终验收 |
| `deploy/kubernetes/jenkins-rbac.yaml` | 保留业务 Namespace 发布权限，并增加 monitoring Namespace 最小观察权限 |
| `scripts/create-phase4-kubeconfig.sh` | 验证现有 Jenkins 身份获得最小监控观察权限且仍无 Secret/Node 权限 |
| `Jenkinsfile` | 定义安全参数、条件阶段、人工批准、结果语义和报告归档 |
| `Makefile` | 暴露 `phase6-contract` 与 `phase6-verify` 操作入口 |
| Phase 6 文档 | 保存真实 Build、Helm、PVC、数据和监控证据以及排障方法 |

---

### Task 1: Phase 6 文件边界与第一版合同

**Files:**
- Create: `scripts/check-phase6-contract.sh`
- Create: `scripts/phase6/common.sh`
- Create: `scripts/phase6/failure-drill.sh`
- Create: `scripts/verify-phase6.sh`
- Modify: `Makefile:1-37,133-134`

**Interfaces:**
- Consumes: 现有 Bash 严格模式和 Makefile 命名约定。
- Produces: `make phase6-contract`、`make phase6-verify`；三个可执行 Phase 6 脚本；后续任务可扩展的静态合同。

- [ ] **Step 1: 写第一版文件合同**

创建 `scripts/check-phase6-contract.sh`，第一版只检查文件结构、严格模式、Make 入口和脚本隔离：

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf '[phase6-contract] ERROR: %s\n' "$1" >&2
  exit 1
}

readonly PHASE6_DIR='scripts/phase6'
readonly DRILL_SCRIPT="$PHASE6_DIR/failure-drill.sh"
readonly COMMON_SCRIPT="$PHASE6_DIR/common.sh"
readonly VERIFY_SCRIPT='scripts/verify-phase6.sh'

for file in "$COMMON_SCRIPT" "$DRILL_SCRIPT" "$VERIFY_SCRIPT"; do
  [[ -f "$file" ]] || fail "$file is missing"
  grep -Fq 'set -Eeuo pipefail' "$file" || fail "$file must use strict Bash mode"
done

grep -Fq 'phase6-contract:' Makefile || fail 'Makefile phase6-contract target is missing'
grep -Fq 'phase6-verify:' Makefile || fail 'Makefile phase6-verify target is missing'
printf '[phase6-contract] Phase 6 file boundary passed\n'
```

- [ ] **Step 2: 运行合同并确认先失败**

Run: `bash scripts/check-phase6-contract.sh`

Expected: FAIL，第一项缺失文件为 `scripts/phase6/common.sh`。

- [ ] **Step 3: 创建安全的最小脚本骨架**

三个脚本均使用 `#!/usr/bin/env bash` 和 `set -Eeuo pipefail`。`common.sh` 只定义日志前缀；`failure-drill.sh` 与 `verify-phase6.sh` 暂时输出清晰的尚未执行提示并返回成功，不访问集群：

```bash
phase6_log() {
  printf '[phase6] %s\n' "$1"
}
```

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
printf '[phase6-drill] scaffold ready; no cluster change was made\n'
```

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
printf '[phase6-verify] scaffold ready; no cluster change was made\n'
```

- [ ] **Step 4: 增加 Make 入口**

把 `phase6-contract phase6-verify` 加入 `.PHONY`，help 增加：

```make
		'  make phase6-contract       Check Phase 6 failure-drill safety contracts' \
		'  make phase6-verify         Verify recovery, persistence, and monitoring'

phase6-contract:
	@bash scripts/check-phase6-contract.sh

phase6-verify:
	@bash scripts/verify-phase6.sh
```

- [ ] **Step 5: 验证骨架与合同**

```bash
bash -n scripts/check-phase6-contract.sh scripts/phase6/common.sh scripts/phase6/failure-drill.sh scripts/verify-phase6.sh
make phase6-contract
```

Expected: Bash 语法检查和第一版合同均 PASS；没有访问 Kubernetes。

- [ ] **Step 6: 提交文件边界**

```bash
git add Makefile scripts/check-phase6-contract.sh scripts/phase6 scripts/verify-phase6.sh
git commit -m "test: define phase 6 safety boundary"
```

---

### Task 2: Jenkins 最小监控观察权限

**Files:**
- Modify: `deploy/kubernetes/jenkins-rbac.yaml:49-61`
- Modify: `scripts/create-phase4-kubeconfig.sh:59-61,134-147`
- Modify: `scripts/check-phase4-contract.sh:195-220`
- Modify: `scripts/check-phase6-contract.sh`

**Interfaces:**
- Consumes: `ServiceAccount/devops-platform/jenkins-deployer` 和原有 `k3d-deployer-kubeconfig`。
- Produces: `Role/monitoring/jenkins-monitoring-observer`；Jenkins 可 `get/list/watch` 监控 Pods/Services/Endpoints，并可 `create pods/portforward`；仍不可读取 monitoring Secret。

- [ ] **Step 1: 扩展失败合同**

在 Phase 6 合同中要求 `jenkins-rbac.yaml` 同时包含：

```bash
grep -Fq 'name: jenkins-monitoring-observer' deploy/kubernetes/jenkins-rbac.yaml \
  || fail 'monitoring observer Role is missing'
grep -Fq 'resources: ["pods/portforward"]' deploy/kubernetes/jenkins-rbac.yaml \
  || fail 'monitoring observer cannot create a temporary port-forward'
grep -Fq 'Jenkins identity unexpectedly reads monitoring Secrets' \
  scripts/create-phase4-kubeconfig.sh \
  || fail 'monitoring Secret denial check is missing'
```

- [ ] **Step 2: 运行合同并确认失败**

Run: `make phase6-contract`

Expected: FAIL，提示 monitoring observer Role 缺失。

- [ ] **Step 3: 增加 monitoring Namespace Role 与 RoleBinding**

在现有 RBAC 文件末尾增加：

```yaml
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-monitoring-observer
  namespace: monitoring
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "endpoints"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/portforward"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-monitoring-observer
  namespace: monitoring
subjects:
  - kind: ServiceAccount
    name: jenkins-deployer
    namespace: devops-platform
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-monitoring-observer
```

- [ ] **Step 4: 扩展身份生成器的正反权限验证**

应用 RBAC 后验证：

```bash
docker exec --user jenkins "$JENKINS_CONTAINER" \
  kubectl --kubeconfig "$CONTAINER_KUBECONFIG" auth can-i get pods -n monitoring \
  | grep -Fxq yes || fail 'Jenkins identity cannot observe monitoring Pods'
docker exec --user jenkins "$JENKINS_CONTAINER" \
  kubectl --kubeconfig "$CONTAINER_KUBECONFIG" auth can-i create pods --subresource=portforward -n monitoring \
  | grep -Fxq yes || fail 'Jenkins identity cannot create monitoring port-forward'
monitoring_secret_access="$(docker exec --user jenkins "$JENKINS_CONTAINER" \
  kubectl --kubeconfig "$CONTAINER_KUBECONFIG" auth can-i get secrets -n monitoring || true)"
[[ "$monitoring_secret_access" == no ]] \
  || fail 'Jenkins identity unexpectedly reads monitoring Secrets'
```

同步更新 Phase 4 合同：允许同一 YAML 中出现两个 Namespace 级 Role/RoleBinding，但仍拒绝 `ClusterRole`、`ClusterRoleBinding` 和 `cluster-admin`。

- [ ] **Step 5: 运行静态和实时权限检查**

```bash
make phase4-contract
make phase6-contract
make phase4-kubeconfig
```

Expected: 合同 PASS；原 Jenkins Secret file 凭据无需更换，因为 ServiceAccount Token 未变化；输出确认 monitoring Pods/port-forward 为 `yes`，monitoring Secrets 和 Nodes 为 `no`。

- [ ] **Step 6: 提交最小权限**

```bash
git add deploy/kubernetes/jenkins-rbac.yaml scripts/create-phase4-kubeconfig.sh scripts/check-phase4-contract.sh scripts/check-phase6-contract.sh
git commit -m "feat: grant Jenkins minimal monitoring observation"
```

---

### Task 3: 基线、故障注入、自动恢复与诊断脚本

**Files:**
- Modify: `scripts/phase6/common.sh`
- Modify: `scripts/phase6/failure-drill.sh`
- Modify: `scripts/check-phase6-contract.sh`

**Interfaces:**
- Consumes: `BUILD_NUMBER: string`、`KUBECONFIG: readable file`、现有 Helm Release `devops-platform`、Ingress `http://host.docker.internal:8080`。
- Produces: `failure-drill.sh --preflight` 与 `failure-drill.sh --run`；`reports/phase6-baseline.txt`、`phase6-failure.txt`、`phase6-recovery.txt`、`helm-history.txt`、`kubernetes-events.txt`、`images.txt`。
- Produces functions: `phase6_require_command(name)`, `phase6_require_variable(name)`, `phase6_api(path, curl_args...)`, `phase6_prometheus_query(query)`, `phase6_item_exists(id)`, `phase6_collect_diagnostics()`。

- [ ] **Step 1: 把行为要求写成失败合同**

扩展合同，逐项要求：

```bash
for required_text in \
  'failure-drill-${BUILD_NUMBER}-does-not-exist' \
  '--rollback-on-failure' \
  '--wait=watcher' \
  '--timeout 5m' \
  'trap recovery_guard EXIT INT TERM' \
  'EXPECTED_DRILL_FAILURE' \
  'RECOVERY_FAILURE' \
  'phase6-baseline.txt' \
  'phase6-failure.txt' \
  'phase6-recovery.txt'; do
  grep -Fq -- "$required_text" "$DRILL_SCRIPT" \
    || fail "failure drill contract is missing: $required_text"
done
```

禁止命令使用一个不匹配注释文本的 token 级表达式检查：

```bash
if grep -Ev '^[[:space:]]*#' "$PHASE6_DIR"/*.sh \
  | grep -Eq 'kubectl[[:space:]]+delete[[:space:]]+(namespace|pvc|persistentvolumeclaim|secret)|helm[[:space:]]+uninstall|docker[[:space:]]+(system|image)[[:space:]]+prune'; then
  fail 'Phase 6 scripts contain a forbidden destructive command'
fi
```

- [ ] **Step 2: 运行扩展合同并确认失败**

Run: `make phase6-contract`

Expected: FAIL，提示缺少动态不存在镜像标签。

- [ ] **Step 3: 实现公共函数和固定常量**

`common.sh` 固定以下接口：

```bash
readonly PHASE6_NAMESPACE='devops-platform'
readonly PHASE6_RELEASE='devops-platform'
readonly PHASE6_CHART='deploy/helm/devops-web-platform'
readonly PHASE6_BACKEND_DEPLOYMENT='devops-platform-devops-web-platform-backend'
readonly PHASE6_FRONTEND_DEPLOYMENT='devops-platform-devops-web-platform-frontend'
readonly PHASE6_MYSQL_STATEFULSET='devops-platform-devops-web-platform-mysql'
readonly PHASE6_BACKEND_REPOSITORY='zingzin/devops-web-platform-backend'
readonly PHASE6_APPLICATION_URL="${PHASE6_APPLICATION_URL:-http://host.docker.internal:8080}"
readonly PHASE6_MONITORING_NAMESPACE='monitoring'
readonly PHASE6_PROMETHEUS_SERVICE='kube-prometheus-stack-prometheus'
readonly PHASE6_PROMETHEUS_PORT="${PHASE6_PROMETHEUS_PORT:-29090}"
readonly PHASE6_MARKER_TITLE='Phase 6 rollback persistence'

phase6_require_command() { command -v "$1" >/dev/null 2>&1 || phase6_fail "$1 is missing"; }
phase6_require_variable() { [[ -n "${!1:-}" ]] || phase6_fail "$1 is empty"; }
```

`phase6_api` 必须复用 `Host: localhost`、连接 3 秒和总时长 10 秒；`phase6_prometheus_query` 访问临时 `127.0.0.1:$PHASE6_PROMETHEUS_PORT`；JSON POST 使用 `jq -n --arg` 生成，不拼接用户输入。

- [ ] **Step 4: 实现只读 `--preflight`**

`failure-drill.sh --preflight` 检查：

- `curl helm jq kubectl mktemp` 存在；
- kubeconfig context 为 `jenkins-deployer@devops-platform`，默认 Namespace 为 `devops-platform`；
- Helm Release 为 `deployed`，记录最后成功 revision；
- frontend/backend/MySQL Ready；
- 当前 frontend/backend 镜像均匹配正则 `^git-[0-9a-f]{12}$`；
- MySQL PVC 为 Bound，记录名称与 UID；
- `/healthz`、`/readyz`、`/api/items` 可用；
- monitoring Pods Ready；
- 临时 port-forward 后 Prometheus Target 查询满足：

```jq
[.data.activeTargets[]
  | select(.health == "up"
      and .labels.namespace == "devops-platform"
      and .labels.service == "backend")]
| length == 1
```

把结果写入 `reports/phase6-baseline.txt`；检查失败立即返回非零，不执行 Helm upgrade。

- [ ] **Step 5: 实现 `--run` 故障和诊断路径**

`--run` 先执行相同基线，然后创建唯一持久化任务并记录 ID。故障标签：

```bash
failure_tag="failure-drill-${BUILD_NUMBER}-does-not-exist"
```

使用现有 Release values，仅覆盖 backend：

```bash
set +e
helm upgrade "$PHASE6_RELEASE" "$PHASE6_CHART" \
  --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
  --reuse-values \
  --set-string images.backend.repository="$PHASE6_BACKEND_REPOSITORY" \
  --set-string images.backend.tag="$failure_tag" \
  --rollback-on-failure --wait=watcher --timeout 5m
upgrade_status="$?"
set -e
```

要求 `upgrade_status != 0`；否则标记异常并进入恢复保护。随后采集 backend Deployment/ReplicaSet/Pod、事件、Helm status/history，证明出现 `ErrImagePull` 或 `ImagePullBackOff`，写入 failure、events 和 history 报告。

- [ ] **Step 6: 实现退出恢复保护和最终恢复验证**

在修改集群前安装：

```bash
trap recovery_guard EXIT INT TERM
```

`recovery_guard` 在异常退出时先采集诊断，再检查当前 backend 镜像与健康状态；若未恢复，执行有界的：

```bash
helm rollback "$PHASE6_RELEASE" "$baseline_revision" \
  --kubeconfig "$KUBECONFIG" --namespace "$PHASE6_NAMESPACE" \
  --wait=watcher --timeout 5m
```

最终验证基线镜像、Ready 副本、MySQL、PVC 名称/UID、持久化任务、health/readiness/API、Prometheus Target、monitoring Pods。验证通过后对持久化任务执行一次 API `PUT`，保持原标题，把 description 更新为 `Survived Phase 6 failed-release rollback`、status 更新为 `completed`；重新读取并确认状态后写入：

```text
result=EXPECTED_DRILL_FAILURE
rollback_verified=true
persistence_verified=true
monitoring_verified=true
```

恢复异常写入 `result=RECOVERY_FAILURE` 和 `manual_rollback_revision=${baseline_revision}`，返回非零。脚本完成成功演练后返回 `0`，由 Jenkins 决定红色构建语义。

- [ ] **Step 7: 运行静态验证和无变更预检**

```bash
bash -n scripts/phase6/common.sh scripts/phase6/failure-drill.sh
shellcheck --severity=warning scripts/phase6/common.sh scripts/phase6/failure-drill.sh
make phase6-contract
KUBECONFIG=/tmp/devops-platform-jenkins-kubeconfig BUILD_NUMBER=local-preflight \
  bash scripts/phase6/failure-drill.sh --preflight
```

Expected: 全部 PASS；Helm revision、Deployment 镜像和 Pod UID 在 preflight 前后不变；baseline 报告不含 Secret 值。

- [ ] **Step 8: 提交演练引擎**

```bash
git add scripts/phase6 scripts/check-phase6-contract.sh
git commit -m "feat: add recoverable failed-release drill"
```

---

### Task 4: Jenkins 参数、审批和预期失败语义

**Files:**
- Modify: `Jenkinsfile:4-20,121-131`
- Modify: `scripts/check-phase4-contract.sh:105-150`
- Modify: `scripts/check-phase6-contract.sh`

**Interfaces:**
- Consumes: `scripts/phase6/failure-drill.sh --run`，成功演练返回 `0`，异常恢复返回非零。
- Produces: Jenkins Boolean 参数 `RUN_FAILURE_DRILL=false`；条件阶段 `Failure Drill`；审批者 `zing`；预期错误标识 `EXPECTED_DRILL_FAILURE`。

- [ ] **Step 1: 添加 Jenkins 失败合同**

Phase 6 合同要求 Jenkinsfile 包含：

```bash
for text in \
  "booleanParam(name: 'RUN_FAILURE_DRILL', defaultValue: false" \
  "stage('Failure Drill')" \
  'params.RUN_FAILURE_DRILL' \
  "submitter: 'zing'" \
  'failure-drill.sh --run' \
  'EXPECTED_DRILL_FAILURE'; do
  grep -Fq "$text" Jenkinsfile || fail "Jenkins failure-drill contract is missing: $text"
done
```

合同还要确认 `Failure Drill` 位于 `Smoke Test` 之后，包含 `triggeredBy 'UserIdCause'`，并禁止 `pollSCM` 周围出现把参数强制设为 true 的逻辑。

- [ ] **Step 2: 运行合同并确认失败**

Run: `make phase6-contract`

Expected: FAIL，提示 `RUN_FAILURE_DRILL` 参数缺失。

- [ ] **Step 3: 增加默认关闭参数**

在 `options` 与 `triggers` 之间加入：

```groovy
parameters {
  booleanParam(
    name: 'RUN_FAILURE_DRILL',
    defaultValue: false,
    description: 'Manually run the non-production failed-release rollback drill'
  )
}
```

- [ ] **Step 4: 增加条件演练阶段与人工审批**

在 `Smoke Test` 后加入：

```groovy
stage('Failure Drill') {
  when {
    allOf {
      expression { params.RUN_FAILURE_DRILL }
      triggeredBy 'UserIdCause'
    }
  }
  steps {
    input message: 'Run the non-production failed-release rollback drill?',
      ok: 'Run failure drill',
      submitter: 'zing'
    withCredentials([file(
      credentialsId: 'k3d-deployer-kubeconfig',
      variable: 'KUBECONFIG'
    )]) {
      script {
        int drillStatus = sh(
          script: 'bash scripts/phase6/failure-drill.sh --run',
          returnStatus: true
        )
        if (drillStatus != 0) {
          error("RECOVERY_FAILURE: Phase 6 drill exited with ${drillStatus}")
        }
        currentBuild.description = 'EXPECTED_DRILL_FAILURE: rollback verified'
        error('EXPECTED_DRILL_FAILURE: bad release blocked and rollback verified')
      }
    }
  }
}
```

报告已由全局 `post { always { archiveArtifacts ... } }` 归档，不增加包含凭据的归档路径。

- [ ] **Step 5: 更新 Phase 4 回归合同**

把 Phase 4 `expected_stages` 追加 `Failure Drill`，stage count 从 `9` 调整为 `10`。Phase 4 合同仍检查原九个阶段顺序和正常发布保护项，并额外确认演练阶段在最后。

- [ ] **Step 6: 执行 Jenkins 静态回归**

```bash
make phase4-contract
make phase5-contract
make phase6-contract
```

Expected: 三个合同全部 PASS；Phase 4/5 行为未被删除，Phase 6 参数默认关闭。

- [ ] **Step 7: 提交 Pipeline 集成**

```bash
git add Jenkinsfile scripts/check-phase4-contract.sh scripts/check-phase6-contract.sh
git commit -m "feat: add approved Jenkins failure drill"
```

---

### Task 5: 本机最终验收脚本、回归门禁与主线发布准备

**Files:**
- Modify: `scripts/verify-phase6.sh`
- Modify: `scripts/check-phase6-contract.sh`

**Interfaces:**
- Consumes: 管理员 context `k3d-devops-platform`、应用入口 `http://localhost:8080`、Phase 6 持久化任务。
- Produces: `make phase6-verify` 的最终 `PASS` 结果；真实环境恢复证据；进入主线前的回归门禁。

- [ ] **Step 1: 扩展 verifier 失败合同**

合同要求 `verify-phase6.sh` 包含：

- 固定 context、业务 Namespace、监控 Namespace；
- `trap cleanup EXIT INT TERM`；
- Helm deployed 检查；
- frontend/backend/MySQL Ready 检查；
- PVC UID；
- `PHASE6_MARKER_TITLE`；
- Prometheus Target UP；
- 严重活动告警为空；
- health、ready 与 CRUD；
- 不读取 Secret。

- [ ] **Step 2: 运行合同并确认失败**

Run: `make phase6-contract`

Expected: FAIL，提示 Phase 6 verifier 缺少恢复检查。

- [ ] **Step 3: 实现管理员视角 verifier**

沿用 Phase 5 的 loopback port-forward 和 cleanup 模式，固定：

```bash
readonly CONTEXT='k3d-devops-platform'
readonly APPLICATION_NAMESPACE='devops-platform'
readonly MONITORING_NAMESPACE='monitoring'
readonly APPLICATION_URL='http://localhost:8080'
readonly PHASE6_MARKER_TITLE='Phase 6 rollback persistence'
readonly PROMETHEUS_PORT="${PHASE6_PROMETHEUS_PORT:-29090}"
```

验收顺序：Helm `deployed`；三类工作负载 Ready；业务 PVC Bound；监控 Pods Ready；启动 `127.0.0.1:29090` Prometheus port-forward；Target UP；Prometheus `/api/v1/alerts` 中不存在 `severity="critical"` 的 firing 告警；查找标题完全匹配的 Phase 6 标记且状态为 `completed`；执行 health、ready、列表、新增、更新、删除；最后再次比对 PVC UID。

- [ ] **Step 4: 运行全部本地门禁**

```bash
bash -n scripts/check-phase6-contract.sh scripts/phase6/common.sh scripts/phase6/failure-drill.sh scripts/verify-phase6.sh
shellcheck --severity=warning scripts/check-phase6-contract.sh scripts/phase6/common.sh scripts/phase6/failure-drill.sh scripts/verify-phase6.sh
make phase1-test
make phase3-manifests
make phase4-contract
make phase5-contract
make phase6-contract
```

Expected: 全部 PASS；此时尚未执行 `--run`，集群没有故障注入。

- [ ] **Step 5: 执行敏感信息和变更范围检查**

```bash
git diff main --check
git grep -nE '(BEGIN (RSA |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]+|dckr_pat_[A-Za-z0-9_-]+)' -- . ':!docs/superpowers'
git status --short
git log --oneline main..HEAD
```

Expected: diff 格式正常；敏感信息扫描无结果；只有 Phase 6 计划内文件；提交记录对应 Tasks 1-4。

- [ ] **Step 6: 提交 verifier**

```bash
git add scripts/verify-phase6.sh scripts/check-phase6-contract.sh
git commit -m "test: verify phase 6 recovery state"
```

- [ ] **Step 7: 合并独立分支并推送主线**

在主工作树中执行：

```bash
cd ~/projects/devops-web-platform
git merge --ff-only phase6-failure-recovery
git push origin main
```

Expected: fast-forward 成功；推送时由用户本人输入 SSH 私钥口令；Jenkins Poll SCM 发现新提交。第一次主线构建使用默认 `RUN_FAILURE_DRILL=false`，Failure Drill 显示 skipped，其他阶段全绿，并使 Jenkins 页面加载最新参数定义。

---

### Task 6: 真实红色演练与绿色恢复构建

**Files:**
- Runtime evidence only: Jenkins Build artifacts and screenshots
- Modify after evidence: `docs/implementation/phase-6-failure-recovery.md`

**Interfaces:**
- Consumes: 已更新的 Jenkins `main` Job、两个现有 Credentials、健康的 Phase 5 环境。
- Produces: 一个 `RUN_FAILURE_DRILL=true` 的预期红色 Build；一个 `RUN_FAILURE_DRILL=false` 的绿色 Build；真实 Helm/Pod/PVC/监控证据。

- [ ] **Step 1: 记录演练前健康状态**

```bash
make phase5-status
make phase6-contract
KUBECONFIG=/tmp/devops-platform-jenkins-kubeconfig BUILD_NUMBER=manual-preflight \
  bash scripts/phase6/failure-drill.sh --preflight
```

Expected: 应用和监控健康，baseline 报告生成，未产生新 Helm revision。

- [ ] **Step 2: 在 Jenkins 手动启动参数化演练**

在 `devops-web-platform/main` 选择 `Build with Parameters`，勾选 `RUN_FAILURE_DRILL`，开始构建；到 `Failure Drill` 时由用户 `zing` 点击 `Run failure drill`。不需要输入新密码、PAT 或 Token。

Expected: 前九个正常阶段绿色；Failure Drill 等待人工批准后执行。

- [ ] **Step 3: 验证演练 Build 是“预期红色”**

演练结束后检查：

- Build 总结果红色；
- Description 或 Console 明确包含 `EXPECTED_DRILL_FAILURE`；
- 不包含 `RECOVERY_FAILURE`；
- artifacts 中存在 baseline、failure、recovery、Helm history、events 和 images；
- failure 报告含 `ErrImagePull` 或 `ImagePullBackOff`；
- recovery 报告四个结果字段均为 true；
- artifact 中不存在 kubeconfig、Secret、Token 或 Docker config。

记录该 Build 编号为 `PHASE6_DRILL_BUILD`。

- [ ] **Step 4: 从本机执行恢复验收**

Run: `make phase6-verify`

Expected: PASS，显示 Helm deployed、工作负载 Ready、Phase 6 标记存在、PVC UID 保持、Prometheus Target UP、无 critical firing 告警。

- [ ] **Step 5: 运行后续正常构建**

在 Jenkins 再次选择 `Build with Parameters`，保持 `RUN_FAILURE_DRILL=false` 后运行。

Expected: Failure Drill skipped；所有正常阶段和 Post Actions 全绿。记录 Build 编号为 `PHASE6_RECOVERY_BUILD`。

- [ ] **Step 6: 写入真实验收表并提交**

创建实施文档中的 `Evidence / Value` 表格，从真实输出逐行记录：演练 Build 编号及 `EXPECTED_DRILL_FAILURE`、恢复 Build 编号及 `SUCCESS`、演练前和恢复后的 Helm revision、完整故障镜像标签、恢复后的完整 backend `git-` 镜像标签、持久化任务数字 ID、MySQL PVC UID 前 8 位和 Prometheus Target `UP`。所有值必须从 Jenkins artifacts 和 `make phase6-verify` 输出复制，不使用示例值。

```bash
git add docs/implementation/phase-6-failure-recovery.md
git commit -m "docs: record phase 6 rollback acceptance"
```

---

### Task 7: Runbook、排障记录、架构、技术复核与最终发布

**Files:**
- Create: `docs/runbooks/phase-6-failure-release-recovery.md`
- Create: `docs/troubleshooting/phase-6-failure-recovery.md`
- Create: `docs/reviews/phase-6-technical-review.md`
- Modify: `docs/architecture.md`
- Modify: `README.md`
- Modify: `docs/implementation/phase-6-failure-recovery.md`

**Interfaces:**
- Consumes: Task 6 的两个 Build 编号、归档报告、Helm history、PVC UID 和 Prometheus 结果。
- Produces: 可重复操作 Runbook、真实问题记录、设计对照审查、简历可用事实和 Phase 6 完成状态。

- [ ] **Step 1: 编写安全 Runbook**

Runbook 必须按顺序写清：前置健康检查、如何选择参数、人工审批含义、预期红色判读、如何区分 `EXPECTED_DRILL_FAILURE` 与 `RECOVERY_FAILURE`、如何下载报告、如何运行 `make phase6-verify`、如何启动后续绿色构建、自动恢复失败时按 baseline revision 执行的人工 `helm rollback` 命令。

Runbook 必须使用占位符说明“从报告复制 revision”，不得写入真实密码、Token 或 kubeconfig 内容。

- [ ] **Step 2: 编写真实排障记录**

记录实施期间实际出现的问题。若整个过程没有额外故障，至少记录并解释以下已知风险而不伪造事故：

- Jenkins 首次加载参数后才显示 `Build with Parameters`；
- 演练红色是设计结果，恢复报告决定是否成功；
- Helm timeout 需要等待 Kubernetes 产生拉取失败事件；
- 临时 Prometheus port-forward 端口冲突时使用 `PHASE6_PROMETHEUS_PORT` 覆盖；
- RBAC 拒绝 monitoring Secret 是正确安全结果。

- [ ] **Step 3: 更新架构与 README**

在架构文档增加：

```text
Jenkins RUN_FAILURE_DRILL=true + input
  -> nonexistent backend image
  -> Kubernetes ImagePullBackOff
  -> Helm rollback-on-failure
  -> application/data/PVC/Prometheus verification
  -> expected red build + archived evidence
  -> normal green build
```

README 当前状态改为 Phase 6 完成，增加 `make phase6-contract`、`make phase6-verify` 和简历能力边界；继续声明这不是生产级容灾或混沌工程。

- [ ] **Step 4: 完成设计对照技术复核**

`docs/reviews/phase-6-technical-review.md` 逐项回答：

1. 参数是否默认关闭且只允许人工启用？
2. 故障是否只使用不存在镜像？
3. Helm 自动回滚是否有真实证据？
4. 恢复失败是否存在二次保护和人工命令？
5. MySQL 数据和 PVC 是否保持？
6. Prometheus Target 与监控工作负载是否恢复？
7. 报告是否不含凭据？
8. 预期红色后是否有正常绿色构建？
9. 简历表述是否没有夸大？

每项填写 `PASS` 或具体差距；存在差距时不得把 Phase 6 标记为完成。

- [ ] **Step 5: 运行最终全量验证**

```bash
make phase1-test
make phase3-manifests
make phase4-contract
make phase5-contract
make phase6-contract
make phase6-verify
git diff --check
git grep -nE '(BEGIN (RSA |OPENSSH )?PRIVATE KEY|ghp_[A-Za-z0-9]+|dckr_pat_[A-Za-z0-9_-]+)' -- . ':!docs/superpowers'
git status --short
```

Expected: 所有测试、合同、实时验收和格式检查 PASS；敏感信息扫描无结果；status 只显示本任务文档修改。

- [ ] **Step 6: 提交 Phase 6 文档收尾**

```bash
git add README.md docs/architecture.md docs/implementation/phase-6-failure-recovery.md docs/runbooks/phase-6-failure-release-recovery.md docs/troubleshooting/phase-6-failure-recovery.md docs/reviews/phase-6-technical-review.md
git commit -m "docs: complete phase 6 recovery runbook"
```

- [ ] **Step 7: 推送最终文档并完成最终绿色构建**

```bash
git push origin main
```

Expected: 用户输入 SSH 私钥口令；Jenkins 因 Poll SCM 启动默认参数构建，Failure Drill skipped，最终全绿。该构建用于确认文档提交没有破坏流水线，不再通过补写 Build 编号制造循环提交。

---

## Execution Checkpoints

1. **Checkpoint A — Tasks 1-3:** 文件边界、最小权限和演练脚本完成；只允许执行 `--preflight`，不得注入故障。
2. **Checkpoint B — Tasks 4-5:** Jenkins 参数化与最终 verifier 完成；全部本地门禁通过后才合并、推送主线。
3. **Checkpoint C — Task 6:** 用户人工批准一次真实演练；必须先证明自动恢复，再运行正常绿色构建。
4. **Checkpoint D — Task 7:** 文档、技术复核、敏感信息扫描和最终绿色构建完成，才宣布 Phase 6 完成。

## Rollback During Implementation

- Tasks 1-5 尚未进入主线时，放弃独立工作树即可，不影响运行环境。
- 演练前 preflight 不健康时停止，不执行 Helm upgrade。
- 演练过程中任何异常由 `recovery_guard` 尝试恢复到记录的 baseline revision。
- 自动恢复仍失败时，使用 recovery 报告中的 `manual_rollback_revision` 执行 Runbook 命令；不得删除 PVC、Secret、Namespace 或 Helm Release。
- Jenkins 参数默认关闭，因此修复代码和后续 SCM 构建不会再次自动触发演练。
