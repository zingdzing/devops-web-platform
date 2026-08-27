# Phase 5 Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 DevOps Web Platform 增加一套资源受控、可重复部署并能完成真实告警闭环的 Prometheus/Grafana/Alertmanager 可观测性系统。

**Architecture:** Flask 使用官方 Python Prometheus client 暴露低基数 `/metrics`；应用 Helm Chart 通过 ServiceMonitor、PrometheusRule 和 Dashboard ConfigMap 接入独立 `monitoring` Namespace 中的官方 `kube-prometheus-stack`。监控栈由固定版本 Chart 和精简 values 单独安装，Jenkins 继续部署业务应用并维护监控 CR，实时告警演练由可恢复脚本执行。

**Tech Stack:** Python 3.14、Flask 3.1、prometheus-client 0.26.0、pytest、Helm 3、k3d/Kubernetes、kube-prometheus-stack 87.21.0、Prometheus Operator、Prometheus、Grafana、Alertmanager、Bash、Jenkins。

**Spec:** `docs/superpowers/specs/2026-08-27-phase-5-observability-design.md`

## Global Constraints

- 使用官方 `kube-prometheus-stack` Chart `87.21.0`，所有安装命令显式携带版本，不使用 `latest`。
- 这是官方完整 Chart 的精简配置，不是 Fork、删改版镜像或另一个产品。
- 监控组件部署在 `monitoring` Namespace；业务继续部署在 `devops-platform` Namespace。
- `monitoring.enabled` 默认 `false`，Phase 5 环境和 Jenkins 部署显式设为 `true`。
- Prometheus 单副本、2 天 retention、2 GiB `local-path` PVC；Grafana 与 Alertmanager 使用可重建的临时存储。
- 不实现邮件/聊天通知、Loki、链路追踪、MySQL Exporter、Thanos、remote write、多集群、高可用副本、公网 Ingress 或自动修复。
- 所有页面仅通过绑定 `127.0.0.1` 的 `kubectl port-forward` 访问。
- Grafana 密码只保存在 Kubernetes Secret，不进入 Git、日志、截图或命令历史。
- 指标标签禁止包含任务 ID、标题、查询字符串、IP、异常正文、密码或数据库连接信息。
- 现有 Jenkins 九阶段保持不变；监控栈不在每次应用构建时重装。
- 每一项完成声明必须以自动测试、静态合同和实时验收证据为依据。

---

### Task 1: Flask 指标端点和低基数标签

**Files:**
- Create: `app/backend/metrics.py`
- Create: `app/backend/tests/test_metrics.py`
- Modify: `app/backend/app.py`
- Modify: `app/backend/config.py`
- Modify: `app/backend/requirements.txt`
- Modify: `app/backend/Dockerfile`
- Modify: `deploy/helm/devops-web-platform/templates/backend-configmap.yaml`

**Interfaces:**
- Consumes: `create_app(test_config=None, database=None)` 和 Flask 路由生命周期。
- Produces: `register_metrics(app: Flask) -> CollectorRegistry`；HTTP `GET /metrics`；`app.extensions["prometheus_registry"]`。

- [ ] **Step 1: 固定依赖并写失败测试**

在 `requirements.txt` 增加 `prometheus-client==0.26.0`。创建 `test_metrics.py`，至少断言：

```python
def test_metrics_endpoint_uses_prometheus_content_type(client):
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.content_type.startswith("text/plain")
    assert b"devops_app_info" in response.data

def test_request_uses_route_template_not_item_id(client):
    client.get("/api/items/987654")
    metrics = client.get("/metrics").get_data(as_text=True)
    assert 'endpoint="/api/items/<int:item_id>"' in metrics
    assert "987654" not in metrics

def test_metrics_request_is_not_counted(client):
    first = client.get("/metrics").get_data(as_text=True)
    client.get("/metrics")
    second = client.get("/metrics").get_data(as_text=True)
    assert first == second
```

- [ ] **Step 2: 运行失败测试**

Run: `docker compose run --rm backend python -m pytest tests/test_metrics.py -q`

Expected: FAIL，因为 `/metrics` 尚不存在或依赖尚未安装。

- [ ] **Step 3: 实现专用 Registry 和指标钩子**

`metrics.py` 使用每个 Flask app 独立的 `CollectorRegistry`，避免测试反复创建 app 时重复注册；定义：

```python
BUCKETS = (0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5)

def register_metrics(app: Flask) -> CollectorRegistry:
    registry = CollectorRegistry()
    requests = Counter(
        "devops_http_requests_total",
        "Business HTTP requests",
        ("method", "endpoint", "status"),
        registry=registry,
    )
    duration = Histogram(
        "devops_http_request_duration_seconds",
        "Business HTTP request duration",
        ("method", "endpoint"),
        buckets=BUCKETS,
        registry=registry,
    )
    info = Gauge(
        "devops_app_info", "Application build information", ("version",), registry=registry
    )
    info.labels(version=app.config["APP_VERSION"]).set(1)
```

使用 `time.perf_counter()`，在 `before_request` 保存起点，在 `after_request` 中跳过 `/metrics` 和 `static`；`endpoint` 只取 `request.url_rule.rule`，无匹配路由统一为 `unmatched`。`/metrics` 返回 `generate_latest(registry)` 和 `CONTENT_TYPE_LATEST`。

- [ ] **Step 4: 接入 app 版本和容器文件**

`config.py` 增加 `"APP_VERSION": os.getenv("APP_VERSION", "development")`；`app.py` 在注册业务蓝图后调用 `register_metrics(app)`；Dockerfile 把 `metrics.py` 复制进镜像；Backend ConfigMap 设置：

```yaml
APP_VERSION: {{ .Values.images.backend.tag | quote }}
```

- [ ] **Step 5: 运行指标与回归测试**

Run: `docker compose build backend && docker compose run --rm backend python -m pytest -q`

Expected: 现有 14 项测试和新增指标测试全部 PASS；输出包含 Counter、Histogram `_bucket/_count/_sum` 与 app info。

- [ ] **Step 6: 提交应用指标**

```bash
git add app/backend deploy/helm/devops-web-platform/templates/backend-configmap.yaml
git commit -m "feat: expose low-cardinality Prometheus metrics"
```

---

### Task 2: 应用 Helm Chart 的监控发现接口

**Files:**
- Create: `deploy/helm/devops-web-platform/templates/servicemonitor.yaml`
- Create: `scripts/check-phase5-contract.sh`
- Modify: `deploy/helm/devops-web-platform/values.yaml`
- Modify: `deploy/helm/devops-web-platform/values.schema.json`
- Modify: `deploy/helm/devops-web-platform/templates/backend-service.yaml`
- Modify: `Makefile`

**Interfaces:**
- Consumes: Backend Service 的 `http` 命名端口与 `/metrics`。
- Produces: `monitoring.enabled`、`monitoring.releaseLabel`、`monitoring.interval` values；`ServiceMonitor/devops-web-platform-backend`。

- [ ] **Step 1: 写 monitoring 开关的失败合同**

`check-phase5-contract.sh` 先执行两次 `helm template`：默认渲染必须不含 `monitoring.coreos.com`；带 `--set monitoring.enabled=true` 时必须出现 ServiceMonitor。脚本使用临时目录和 `trap 'rm -rf "$tmp_dir"' EXIT`，失败信息必须指出缺少的资源。

- [ ] **Step 2: 验证合同先失败**

Run: `bash scripts/check-phase5-contract.sh`

Expected: FAIL，提示启用监控时没有 ServiceMonitor。

- [ ] **Step 3: 增加 values 与 schema**

在 `values.yaml` 增加：

```yaml
monitoring:
  enabled: false
  releaseLabel: kube-prometheus-stack
  interval: 30s
```

在 JSON Schema 中为三个字段声明 `boolean/string/string`，`interval` 使用 `^[0-9]+(ms|s|m|h)$`，并保持 `additionalProperties: false`。

- [ ] **Step 4: 创建 ServiceMonitor**

模板只在 `monitoring.enabled` 时渲染，位于 `devops-platform`，包含 `release: {{ .Values.monitoring.releaseLabel }}`；selector 选择应用实例和 backend component；endpoint 使用 `port: http`、`path: /metrics`、配置的 interval。

- [ ] **Step 5: 运行 lint、模板和合同**

```bash
helm lint deploy/helm/devops-web-platform
helm template test deploy/helm/devops-web-platform >/tmp/phase5-off.yaml
helm template test deploy/helm/devops-web-platform --set monitoring.enabled=true >/tmp/phase5-on.yaml
bash scripts/check-phase5-contract.sh
```

Expected: 全部 PASS；off 无监控 CR，on 有且 selector/port/path 正确。

- [ ] **Step 6: 增加 `make phase5-contract` 并提交**

```bash
git add deploy/helm/devops-web-platform scripts/check-phase5-contract.sh Makefile
git commit -m "feat: add Prometheus service discovery contract"
```

---

### Task 3: 项目告警规则和 Grafana Dashboard

**Files:**
- Create: `deploy/helm/devops-web-platform/templates/prometheusrule.yaml`
- Create: `deploy/helm/devops-web-platform/templates/grafana-dashboard.yaml`
- Create: `deploy/monitoring/dashboards/devops-web-platform-overview.json`
- Modify: `scripts/check-phase5-contract.sh`

**Interfaces:**
- Consumes: `devops_*` 指标、kube-state-metrics、kubelet/cAdvisor 指标和 Grafana sidecar label。
- Produces: 三条 PrometheusRule 和一个 Git 管理的 `DevOps Web Platform Overview` Dashboard。

- [ ] **Step 1: 扩展失败合同**

合同断言启用监控后恰好存在：`BackendTargetMissing`、`DeploymentReplicasUnavailable`、`ContainerRestartingFrequently`；每条有 `severity`、summary、description、runbook；Dashboard JSON 可被 `jq empty` 解析且含九个 panel title。

- [ ] **Step 2: 验证扩展合同先失败**

Run: `bash scripts/check-phase5-contract.sh`

Expected: FAIL，提示缺少 PrometheusRule 或 Dashboard。

- [ ] **Step 3: 实现三条告警规则**

使用以下表达式和 `for: 1m`：

```promql
absent(up{namespace="devops-platform",service="devops-web-platform-backend"} == 1)

kube_deployment_spec_replicas{namespace="devops-platform",deployment=~"devops-web-platform-(frontend|backend)"}
  > kube_deployment_status_replicas_available{namespace="devops-platform",deployment=~"devops-web-platform-(frontend|backend)"}

increase(kube_pod_container_status_restarts_total{namespace="devops-platform",container=~"frontend|backend"}[10m]) >= 3
```

实施时必须在真实 Target 页面核对 `service` label；若实际 label 不同，修改表达式和合同为真实稳定标签，并在实施记录说明。

- [ ] **Step 4: 创建 Dashboard JSON 和供应 ConfigMap**

Dashboard datasource UID 固定为 `prometheus`，变量 `namespace` 默认 `devops-platform`。九个 panel 分别为 Target、RPS、5xx、P95、Deployment replicas、Pod Ready、restart delta、CPU、memory。ConfigMap 使用 Chart sidecar 要求的标签并把完整 JSON 放在 `data` 中。

- [ ] **Step 5: 验证 JSON、Helm 和合同**

```bash
jq empty deploy/monitoring/dashboards/devops-web-platform-overview.json
helm lint deploy/helm/devops-web-platform
bash scripts/check-phase5-contract.sh
```

Expected: PASS，且项目告警只有三条、Dashboard 只有一个。

- [ ] **Step 6: 提交规则和 Dashboard**

```bash
git add deploy/helm/devops-web-platform deploy/monitoring scripts/check-phase5-contract.sh
git commit -m "feat: add project alerts and Grafana dashboard"
```

---

### Task 4: 固定版本的精简监控栈安装入口

**Files:**
- Create: `deploy/monitoring/kube-prometheus-stack-values.yaml`
- Create: `scripts/create-phase5-grafana-secret.sh`
- Create: `scripts/install-phase5-monitoring.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: Kubernetes context `k3d-devops-platform` 和用户创建的 `monitoring/grafana-admin` Secret。
- Produces: Helm release `kube-prometheus-stack`、Namespace `monitoring`、固定 Chart 版本 `87.21.0`。

- [ ] **Step 1: 在合同中固定版本和禁用项**

合同检查 values 包含：Prometheus retention `2d`、PVC `2Gi`、单副本；Alertmanager/Grafana 单副本；Windows exporter、Thanos、etcd/scheduler/controller-manager 抓取和无关默认 Dashboard/规则关闭；所有核心组件存在 resources requests/limits。

- [ ] **Step 2: 写精简 values 并验证 YAML**

创建 values，保留 operator、Prometheus、Alertmanager、Grafana、kube-state-metrics、node-exporter、kubelet/cAdvisor、ServiceMonitor/Rule/Dashboard sidecar。Grafana 使用 `admin.existingSecret: grafana-admin`，datasource UID 固定 `prometheus`，所有 Service 为 ClusterIP，无 Ingress。

Run: `helm show values prometheus-community/kube-prometheus-stack --version 87.21.0 >/tmp/kps-defaults.yaml`

Expected: 成功获取固定版本默认值；逐项确认自定义 key 与该版本一致。

- [ ] **Step 3: 创建只处理密码的用户脚本**

`create-phase5-grafana-secret.sh` 必须交互式使用 `read -rsp` 读取两次密码，拒绝空值和不一致值，并执行：

```bash
kubectl --context k3d-devops-platform create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl --context k3d-devops-platform -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$password" \
  --dry-run=client -o yaml | kubectl apply -f -
```

脚本不得打印密码。

- [ ] **Step 4: 实现幂等安装脚本**

安装脚本检查当前 context 和 Secret，添加官方 Helm repo，然后：

```bash
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 87.21.0 --namespace monitoring --create-namespace \
  --values deploy/monitoring/kube-prometheus-stack-values.yaml \
  --wait --timeout 10m
```

随后等待 operator、Grafana、Prometheus 和 Alertmanager Ready；失败只收集状态和 Events，不卸载业务资源。

- [ ] **Step 5: 增加 Make 入口并执行静态验证**

增加 `phase5-grafana-secret`、`phase5-install`、`phase5-status`。运行 `make phase5-contract`，Expected: PASS。

- [ ] **Step 6: 用户创建 Secret 后安装监控栈**

Run: `make phase5-grafana-secret`（用户本人输入）然后 `make phase5-install`。

Expected: monitoring Namespace 核心 Pod Ready，Prometheus PVC Bound。

- [ ] **Step 7: 提交安装边界**

```bash
git add deploy/monitoring scripts Makefile
git commit -m "feat: add pinned lightweight monitoring stack"
```

---

### Task 5: Jenkins 持续部署与最小权限延续

**Files:**
- Modify: `deploy/kubernetes/jenkins-rbac.yaml`
- Modify: `scripts/ci/deploy.sh`
- Modify: `scripts/ci/quality-check.sh`
- Modify: `scripts/check-phase4-contract.sh`
- Modify: `scripts/check-phase5-contract.sh`

**Interfaces:**
- Consumes: 已安装的 Prometheus Operator CRD 和现有 `jenkins-deployer` kubeconfig。
- Produces: Jenkins 对 devops-platform 内 ServiceMonitor/PrometheusRule 的 CRUD 权限，以及业务发布时固定启用监控模板。

- [ ] **Step 1: 写失败合同**

合同断言 RBAC 仅在 namespaced Role 中授予 `monitoring.coreos.com` 的 `servicemonitors`、`prometheusrules` CRUD；`deploy.sh` 必须含 `--set monitoring.enabled=true`；quality check 必须调用 `make phase5-contract`。

- [ ] **Step 2: 运行合同确认失败**

Run: `make phase4-contract && make phase5-contract`

Expected: Phase 5 相关断言 FAIL。

- [ ] **Step 3: 扩展 Role 与部署参数**

RBAC 增加：

```yaml
- apiGroups: ["monitoring.coreos.com"]
  resources: ["servicemonitors", "prometheusrules"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

`deploy.sh` 的 Helm 命令增加 `--set monitoring.enabled=true`；quality check 调用 Phase 5 合同。不要增加 cluster-admin、ClusterRole 或访问 monitoring Namespace Secret 的权限。

- [ ] **Step 4: 应用 RBAC 并验证授权**

```bash
kubectl --context k3d-devops-platform apply -f deploy/kubernetes/jenkins-rbac.yaml
kubectl --context k3d-devops-platform auth can-i create servicemonitors.monitoring.coreos.com \
  -n devops-platform --as system:serviceaccount:devops-platform:jenkins-deployer
kubectl --context k3d-devops-platform auth can-i get secrets \
  -n monitoring --as system:serviceaccount:devops-platform:jenkins-deployer
```

Expected: 第一条 `yes`，第二条 `no`。

- [ ] **Step 5: 运行全部静态合同并提交**

```bash
make phase4-contract
make phase5-contract
git add deploy/kubernetes scripts/ci scripts/check-phase4-contract.sh scripts/check-phase5-contract.sh
git commit -m "ci: deploy application monitoring resources"
```

---

### Task 6: 本机安全访问和状态检查

**Files:**
- Create: `scripts/phase5-port-forward.sh`
- Create: `scripts/phase5-status.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: monitoring release Services。
- Produces: `make phase5-prometheus`、`phase5-grafana`、`phase5-alertmanager`、`phase5-status`。

- [ ] **Step 1: 写脚本参数合同**

合同检查只接受 `prometheus|grafana|alertmanager`，端口分别为 `9090|3000|9093`，所有转发地址必须显式为 `127.0.0.1`，未知参数退出码非零。

- [ ] **Step 2: 实现阻塞式端口转发**

脚本映射组件到固定 Service 和端口，先验证 Pod Ready，再执行：

```bash
kubectl --context k3d-devops-platform -n monitoring port-forward \
  --address 127.0.0.1 "service/$service" "$local_port:$remote_port"
```

不后台化、不创建公网 Service，并提示用 `Ctrl+C` 停止。

- [ ] **Step 3: 实现状态脚本**

输出 Helm status、核心 Pod、Prometheus PVC、应用 ServiceMonitor/PrometheusRule 和业务 workload 状态，不读取或打印 Secret。

- [ ] **Step 4: 验证三个入口**

分别运行 Make target，使用浏览器访问 localhost 对应端口后 `Ctrl+C`。Expected: Prometheus Targets、Grafana 登录页、Alertmanager 页面可访问，其他网卡不监听。

- [ ] **Step 5: 提交运维入口**

```bash
git add scripts/phase5-port-forward.sh scripts/phase5-status.sh Makefile scripts/check-phase5-contract.sh
git commit -m "ops: add local monitoring access commands"
```

---

### Task 7: 自动实时验收与真实告警演练

**Files:**
- Create: `scripts/verify-phase5.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `BackendTargetMissing`、Prometheus/Alertmanager HTTP API、backend Deployment、现有 CRUD API 和持久化任务 ID。
- Produces: `make phase5-verify`，无论成功或失败都尽力恢复 backend 原副本数。

- [ ] **Step 1: 写验收前置检查**

脚本使用 `set -Eeuo pipefail`，检查 context、核心 Pod Ready、PVC Bound、CR 存在；记录 backend 原副本数，并注册 trap：

```bash
restore_backend() {
  kubectl --context k3d-devops-platform -n devops-platform scale deployment/devops-web-platform-backend \
    --replicas="$original_replicas" || true
}
trap restore_backend EXIT INT TERM
```

- [ ] **Step 2: 实现 API 级指标验收**

在临时本地端口启动 Prometheus/Alertmanager port-forward，循环等待 API Ready；检查 backend Target `health=up`；执行 `up`、Counter、P95、Deployment/Pod/restart/CPU/memory 查询并要求返回非空 series；检查三条 rule 已加载且初始非 Firing。

- [ ] **Step 3: 记录业务持久化基线**

通过现有 Ingress/API 创建标题为 `Phase 5 alert persistence` 的任务，保存返回 ID；确认读取成功。禁止复用硬编码 ID 或删除用户已有数据。

- [ ] **Step 4: 触发真实 Firing**

缩容 backend 到 0，轮询 Prometheus rules API，最多等待 3 分钟，要求 `BackendTargetMissing` 进入 Firing；再轮询 Alertmanager API，要求同名活动告警存在。超时收集 Target、Rule、Pod 和 Events 到安全诊断目录。

- [ ] **Step 5: 恢复并证明 Resolved**

恢复原副本，等待 rollout 和 `/readyz`；要求 Target 回到 UP、Prometheus rule 回到 Inactive、Alertmanager 活动告警消失。不得通过删除 Rule 或 Alertmanager 数据伪造恢复。

- [ ] **Step 6: 验证业务和持久化**

检查 Ingress、`/healthz`、`/readyz`、CRUD，并用保存的任务 ID 证明数据仍存在；最后显式调用 restore 并清除 trap。

- [ ] **Step 7: 执行两次验收验证幂等性**

Run: `make phase5-verify && make phase5-verify`

Expected: 两次 PASS；backend 副本恢复；只有验收创建的两条任务数据新增；MySQL PVC 未变化。

- [ ] **Step 8: 提交验收脚本**

```bash
git add scripts/verify-phase5.sh Makefile
git commit -m "test: verify observability and alert recovery"
```

---

### Task 8: 文档、故障记录与最终证据

**Files:**
- Create: `docs/implementation/phase-5-observability.md`
- Create: `docs/runbooks/phase-5-monitoring-operations.md`
- Create: `docs/troubleshooting/phase-5-observability.md`
- Create: `docs/reviews/phase-5-technical-review.md`
- Modify: `README.md`
- Modify: `deploy/README.md`
- Modify: `docs/architecture.md`
- Modify: `docs/superpowers/specs/2026-08-27-phase-5-observability-design.md`

**Interfaces:**
- Consumes: 实际执行输出、真实 Target/Rule/Alert 状态和 Jenkins 构建证据。
- Produces: 可复现 Runbook、仅记录真实事故的 troubleshooting、Phase 5 独立技术复核结论和简历可用事实。

- [ ] **Step 1: 把设计状态改为已确认**

将 spec 的状态改为 `已确认，进入实施`，保留确认日期，不改写已经批准的范围。

- [ ] **Step 2: 编写实施记录**

记录版本、命令、资源边界、实际安装结果、Target 标签、PromQL 验证、告警触发/恢复时间和持久化任务 ID；不得写密码、Secret 内容或虚构结果。

- [ ] **Step 3: 编写操作 Runbook**

覆盖安装/升级、状态、三个端口转发、Grafana 密码重置、Target DOWN、Rule 不加载、告警不恢复、停止/卸载边界；明确卸载 monitoring release 不应删除业务/MySQL/Jenkins 数据。

- [ ] **Step 4: 记录真实问题**

只把实施中真实发生的问题写进 troubleshooting，格式为现象、证据、根因、修复、复验。若某类问题未发生，明确“不记录假想事故”，不编造案例。

- [ ] **Step 5: 运行完整本地验收**

```bash
docker compose run --rm backend python -m pytest -q
make phase4-contract
make phase5-contract
make phase5-status
make phase5-verify
git grep -nEi '(password|token|secret).*(=|:)[[:space:]]*[^<{[:space:]]+' -- ':!docs/superpowers' || true
git status --short
```

Expected: 测试/合同/实时验收 PASS；无凭据命中；仅预期文档变更。

- [ ] **Step 6: 提交文档并推送**

```bash
git add README.md deploy/README.md docs
git commit -m "docs: complete phase 5 observability runbook"
git push origin main
```

- [ ] **Step 7: 运行 Jenkins 并保存证据**

在 Jenkins `devops-web-platform/main` 点击一次 Build Now。Expected: 现有九阶段全绿，pytest 报告和镜像清单正常归档，Deploy 后应用监控 CR 保留且 Smoke Test PASS。

- [ ] **Step 8: 进行独立技术复核**

复核 spec 全部目标/非目标、RBAC 最小权限、秘密边界、Chart 固定版本、低基数指标、告警恢复和 Jenkins 连续性；把 blocker/major/minor 及修复状态写入 `docs/reviews/phase-5-technical-review.md`。所有 blocker 和 major 修复并重新验收后才能标记 Phase 5 完成。

- [ ] **Step 9: 最终提交复核结果**

```bash
git add docs/reviews/phase-5-technical-review.md
git commit -m "docs: record phase 5 technical review"
git push origin main
```

Expected: `git status --short` 为空；最新 Jenkins 构建全绿；`make phase5-verify` PASS。
