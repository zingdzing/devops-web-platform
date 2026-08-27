# Phase 5 可观测性与告警设计

日期：2026-08-27  
状态：已确认，进入实施
项目：DevOps Web Platform

## 1. 背景

Phase 0 至 Phase 4 已完成本地开发环境、Flask/MySQL 业务应用、Docker Compose、k3d/Kubernetes、NGINX Ingress、Helm 和 Jenkins CI/CD。当前系统能够自动测试、构建镜像、推送 Docker Hub 并发布到 Kubernetes，但发布之后主要依赖人工访问页面、健康检查和 `kubectl` 判断状态。

Phase 5 增加一个范围受控的可观测性子系统，使项目能够回答三个问题：

1. 应用现在是否可用；
2. 请求量、错误率和延迟如何变化；
3. 服务异常时能否自动产生告警，并在恢复后自动解除。

本阶段面向初级 DevOps 简历项目，不建设生产级监控平台。

## 2. Prometheus 在本项目中的含义

Prometheus 是本阶段的指标采集、时序存储、查询和告警规则计算核心。它通过 HTTP 主动抓取监控目标暴露的指标，把带时间戳和标签的数值保存为时间序列，并使用 PromQL 查询和聚合数据。

招聘说明中的“会使用 Prometheus”通常应能够落实为以下能力：

- 理解 Counter、Gauge、Histogram 等指标类型；
- 为应用或 Exporter 暴露 `/metrics`；
- 配置 Kubernetes 服务发现或 ServiceMonitor；
- 查看 Target 和排查 `UP/DOWN`；
- 使用 PromQL 查询请求量、错误率、延迟和资源指标；
- 编写告警规则并把告警交给 Alertmanager；
- 与 Grafana 组合展示指标；
- 控制标签基数、数据保留时间和资源使用。

Phase 5 会实际覆盖上述核心能力，而不是只安装一个带有 Prometheus 名称的容器。

官方参考：

- [Prometheus Overview](https://prometheus.io/docs/introduction/overview/)
- [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/)
- [Prometheus Alerting Overview](https://prometheus.io/docs/alerting/latest/overview/)

## 3. 目标

Phase 5 必须实现：

- Flask 后端暴露低基数的业务 HTTP 指标；
- Prometheus 自动发现并抓取后端指标；
- 采集 Kubernetes Deployment、Pod、容器重启及资源指标；
- 提供一个项目专用 Grafana Dashboard；
- 加载三条项目专用 PrometheusRule；
- 在 Alertmanager 页面观察真实 Firing，并在恢复后通过告警消失和 Prometheus 规则回到 Inactive 证明 Resolved；
- 验证告警演练后应用、Ingress 和 MySQL 持久化数据正常；
- 提供可重复执行的安装、访问、验收和停止入口；
- 保存实际遇到的故障、证据、根因和解决方法；
- 更新 README、架构和实施记录，但只描述通过验收的能力。

## 4. 非目标

本阶段不加入：

- 邮件、短信、钉钉、企业微信或其他外部通知渠道；
- Loki、ELK、OpenSearch 等日志平台；
- Jaeger、Tempo 或 OpenTelemetry 链路追踪；
- MySQL Exporter 和数据库内部性能调优；
- Thanos、远程写入、对象存储和长期历史数据；
- 多集群、联邦 Prometheus 或高可用副本；
- 公网 Ingress、TLS 和身份认证代理；
- 自动修复脚本或告警触发后的自动回滚；
- 云监控服务和需要付费的外部平台。

这些能力不应出现在 Phase 5 的完成声明或简历描述中。

## 5. 方案选择

采用精简配置的 `kube-prometheus-stack` Helm Chart，而不是手工分别安装 Prometheus、Grafana 和 Alertmanager，也不在 Docker Compose 中建立独立监控栈。

计划锁定 Chart `87.21.0`。该 Chart 要求 Kubernetes `>=1.25.0`，当前 k3d/K3s Server 为 `v1.36.1+k3s1`，满足版本条件。实施开始前只允许进行一次兼容性复核；若版本发生变化，必须在实施计划中明确记录新的固定版本，不能使用不带版本的安装命令。

官方 Chart 将 Prometheus Operator、Prometheus、Alertmanager、Grafana、kube-state-metrics、node-exporter、规则和仪表盘组合为 Kubernetes 监控栈。精简版不是另一个软件或删改后的 Fork，而是同一个 Chart 配合项目专用 `values.yaml` 关闭不需要的功能、缩小副本和资源、减少默认内容。

官方参考：

- [kube-prometheus-stack Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator)

## 6. 精简版与默认完整配置的边界

### 6.1 保留

- Prometheus Operator 和必要 CRD；
- 单副本 Prometheus；
- 单副本 Alertmanager；
- 单副本 Grafana；
- kube-state-metrics；
- node-exporter；
- kubelet/cAdvisor 指标采集；
- ServiceMonitor、PrometheusRule 和 Grafana sidecar；
- 项目专用 Dashboard 和告警规则；
- Prometheus 2 天数据保留；
- Prometheus 2 GiB `local-path` PVC。

### 6.2 关闭或缩减

- Windows Exporter；
- Thanos、remote write 和高可用副本；
- Admission Webhook Patch Job 之外不必要的附加 Job；
- k3d 中不可访问或噪声较高的 etcd、scheduler、controller-manager 监控；
- 与本项目无关的大量默认 Grafana Dashboard；
- 与单节点教学环境不匹配的默认集群告警规则组；
- Alertmanager 持久化和外部 Receiver；
- Grafana 持久化数据库：Dashboard 通过 ConfigMap 自动供应，不依赖页面手工保存；
- 公网 Service、LoadBalancer 和 Ingress。

### 6.3 资源边界

所有组件均设置 requests/limits，单组件不得无边界使用资源。设计目标是监控栈稳定状态下总内存 requests 不超过约 1 GiB、limits 不超过约 2 GiB；实际值在实施计划中根据 Chart 模板和本机验证确定。

若 Docker Desktop 资源不足，优先减少默认规则、Dashboard、保留时间和资源 limits，不删除 Prometheus、Grafana、Alertmanager 或项目告警闭环。

## 7. 总体架构

监控组件部署在独立的 `monitoring` Namespace，业务继续位于 `devops-platform` Namespace。

```text
Flask /metrics
      |
      v
Backend Service -> ServiceMonitor -> Prometheus
                                      |      |
Kubernetes API -> kube-state-metrics -+      +-> PrometheusRule
Kubelet/cAdvisor ----------------------+              |
                                      |              v
                                      +-> Grafana  Alertmanager
```

职责边界：

- Flask 只负责产生应用指标，不连接 Grafana 或 Alertmanager；
- ServiceMonitor 只声明如何发现和抓取 Backend Service；
- Prometheus 负责抓取、存储、PromQL 和规则计算；
- Grafana 只查询 Prometheus 并显示 Dashboard；
- Alertmanager 负责聚合、去重、静默和显示告警状态，本阶段不向外部发送消息；
- kube-state-metrics 把 Kubernetes 对象状态转换为指标；
- node-exporter 与 kubelet/cAdvisor 提供节点、Pod 和容器资源指标。

## 8. 应用指标设计

后端使用 Python 官方 `prometheus_client` 库暴露 `/metrics`。不修改现有业务 API 语义，也不新增专门制造错误的业务接口。

项目指标前缀统一为 `devops_`：

| 指标 | 类型 | 标签 | 用途 |
|---|---|---|---|
| `devops_http_requests_total` | Counter | `method`, `endpoint`, `status` | 请求量和错误率 |
| `devops_http_request_duration_seconds` | Histogram | `method`, `endpoint` | 平均值和 P95 延迟 |
| `devops_app_info` | Gauge | `version` | 当前应用版本信息 |

约束：

- `endpoint` 使用 Flask 路由模板或稳定 endpoint 名称，禁止使用包含 ID、查询字符串的原始 URL；
- 不把用户名、任务标题、IP、异常文本等高基数或隐私数据放进标签；
- `/metrics`、静态文件和不需要统计的内部请求不得递归污染业务指标；
- Histogram buckets 使用适合本地 Web 请求的有限集合，不创建动态 bucket；
- `/metrics` 不包含 Secret、数据库连接串或请求正文。

现有 `/healthz` 和 `/readyz` 继续承担健康检查职责；`/metrics` 只用于指标抓取。

## 9. Kubernetes 发现设计

在应用 Helm Chart 中增加可开关的监控模板：

- Backend Service 增加稳定的监控标签和命名端口；
- `ServiceMonitor` 选择 Backend Service，并访问 `/metrics`；
- `PrometheusRule` 保存项目三条告警；
- Grafana Dashboard 以带固定标签的 ConfigMap 交给 sidecar 自动加载。

`monitoring.enabled` 默认值为 `false`，Phase 5 环境显式设置为 `true`。这样应用 Chart 在没有安装 Prometheus Operator CRD 的 Compose/早期环境中仍然可以渲染和使用。

Prometheus 的 ServiceMonitor/PrometheusRule selector 只接收带项目约定标签的资源，避免无意抓取所有 Namespace 的任意对象。

## 10. Grafana Dashboard

只创建一个名为 `DevOps Web Platform Overview` 的项目 Dashboard，所有面板来自 Git 中的 JSON/ConfigMap，不把页面手工操作作为唯一事实来源。

面板范围：

1. Backend Target 状态；
2. 每秒请求量；
3. HTTP 5xx 错误率；
4. HTTP P95 响应时间；
5. frontend/backend Deployment 期望和可用副本；
6. devops-platform Namespace 内 Pod Ready 状态；
7. 容器最近 15 分钟重启增量；
8. 业务 Pod CPU 使用率；
9. 业务 Pod 内存工作集。

Dashboard 使用 `namespace` 变量，但默认且验收值固定为 `devops-platform`。不创建多集群和多环境变量。

示例 PromQL 设计：

```promql
sum(rate(devops_http_requests_total[5m]))

100 * sum(rate(devops_http_requests_total{status=~"5.."}[5m]))
  / clamp_min(sum(rate(devops_http_requests_total[5m])), 0.001)

histogram_quantile(
  0.95,
  sum by (le) (rate(devops_http_request_duration_seconds_bucket[5m]))
)
```

具体 label selector 必须以实际 ServiceMonitor 生成的 Target 标签为准，在实施时通过 Prometheus Targets 页面和 PromQL 查询验证，不能凭空假设。

## 11. 告警规则

### 11.1 BackendTargetMissing

条件：Prometheus 连续 1 分钟找不到 Backend ServiceMonitor 目标或目标没有 `up == 1`。

目的：检测后端副本为零、Service 无 Endpoint、抓取端口错误或应用无法提供 `/metrics`。

### 11.2 DeploymentReplicasUnavailable

条件：`devops-platform` 中 frontend 或 backend Deployment 的期望副本大于可用副本，持续 1 分钟。

目的：检测镜像启动失败、探针失败和发布后副本不足。

### 11.3 ContainerRestartingFrequently

条件：目标 Namespace 中某业务容器 10 分钟内重启次数增加至少 3 次，持续 1 分钟。

目的：检测 CrashLoop、反复探针失败或不稳定进程。

所有规则必须包含：

- `severity`；
- `service` 或 `namespace` 等稳定标签；
- 简短 summary；
- 可执行 description；
- 对应 Runbook 路径或说明。

本阶段不配置 Receiver。Alertmanager 页面是验收观察点，告警的来源和状态仍然真实。

## 12. 告警演练

主要演练使用 `BackendTargetMissing`：

1. 记录 backend Deployment 当前副本数和持久化任务数据；
2. 确认 Backend Target 为 `UP`，Alertmanager 没有项目告警；
3. 临时把 backend Deployment 缩容到 0；
4. 等待 Service Endpoint/Target 消失；
5. 在 Prometheus Alerts 和 Alertmanager 页面确认 `BackendTargetMissing` 为 Firing；
6. 把 backend 恢复到原副本数；
7. 等待 rollout、readiness 和 Target 恢复；
8. 确认 Alertmanager 不再显示活动告警，同时 Prometheus 规则回到 Inactive，以此证明 Resolved；不通过删除规则伪造恢复；
9. 验证 Ingress 页面、`/healthz`、`/readyz` 和 CRUD API；
10. 验证演练前的 MySQL 任务数据仍然存在。

演练脚本必须使用 trap 或等效机制尽力恢复原副本数。验收失败时保留可安全公开的 Prometheus Target、Rule、Alertmanager、Pod 和事件诊断，不记录 Secret。

## 13. 访问和凭据边界

三个管理页面只通过本机 `kubectl port-forward` 访问：

- Prometheus：`127.0.0.1:9090`；
- Grafana：`127.0.0.1:3000`；
- Alertmanager：`127.0.0.1:9093`。

不创建 Ingress、NodePort 或 LoadBalancer。

Grafana 管理员密码由本地脚本生成并保存为 `monitoring` Namespace 中的 Secret。Git 只保存 Secret 名称和使用说明，不保存密码明文、Base64 值、导出的 Secret 或截图。用户需要查看或输入密码时由用户本人操作。

Prometheus 和 Alertmanager 页面仅绑定 localhost 端口转发；这不等于生产级认证方案，文档必须明确其本地实验边界。

## 14. 数据和持久化边界

- Prometheus 使用 2 GiB `local-path` PVC，retention 为 2 天，同时设置容量边界；
- Grafana Dashboard、Datasource 和组织结构由配置供应，Grafana 使用临时存储即可复建；
- Alertmanager 不配置外部 Receiver，状态使用临时存储；
- 卸载监控 Helm Release 不得删除业务 Namespace、MySQL PVC 或 Jenkins Home；
- 删除整个 k3d 集群仍会丢失 local-path 数据，这一限制延续 Phase 3，不包装成跨集群持久化。

## 15. 仓库结构

计划新增或修改的边界如下，具体任务拆分由后续实施计划确定：

```text
backend/
  requirements.txt
  app metrics integration

deploy/
  helm/devops-web-platform/
    templates/servicemonitor.yaml
    templates/prometheusrule.yaml
    templates/grafana-dashboard.yaml
    values.yaml
  monitoring/
    kube-prometheus-stack-values.yaml

scripts/
  phase5 installation/access/verification scripts

docs/
  implementation/phase-5-observability.md
  runbooks/phase-5-monitoring-operations.md
  troubleshooting/phase-5-observability.md
```

Makefile 提供稳定入口，避免用户记忆长命令：安装/升级、状态、端口转发、合同检查、实时验收和停止。

## 16. Jenkins 边界

Phase 5 不让 Jenkins 长期运行端口转发，也不让每次普通应用提交重新安装整个监控栈。

Jenkins Pipeline 必须继续执行现有九阶段，并增加与本次变更相称的验证：

- Python 单元测试覆盖指标端点和标签边界；
- Helm lint/template 能在 monitoring 开关开启与关闭时通过；
- 静态合同检查验证 ServiceMonitor、PrometheusRule、Dashboard 和固定 Chart 版本；
- 发布后 Smoke Test 继续验证业务，不以 Grafana 页面加载替代应用验收。

监控栈的首次安装和受控升级由 Make/Runbook 明确执行，避免把重量级基础设施安装混入每次业务发布。

## 17. 失败处理

| 故障 | 处理边界 |
|---|---|
| Helm 安装超时 | 收集 monitoring Pod、Events、PVC、CRD 和 Helm 状态；不删除业务集群 |
| Prometheus Target DOWN | 检查 Service selector、Endpoint、端口名、路径和 NetworkPolicy |
| ServiceMonitor 未发现 | 检查 CRD、Namespace selector、Prometheus selector 和资源标签 |
| Grafana 无数据 | 先在 Prometheus 执行同一 PromQL，再检查 Datasource 和 Dashboard 变量 |
| 告警不触发 | 检查 Rule 是否加载、表达式当前值、`for` 时间和 Alertmanager连接 |
| 告警不恢复 | 恢复副本并确认 Target/表达式正常，不能通过删除规则掩盖问题 |
| 本机资源不足 | 缩减默认规则/Dashboard、retention 和资源配置；保留核心闭环 |
| CRD/Chart 升级不兼容 | 停止升级，保留固定版本和诊断，按官方升级说明处理 |

实际排障文档只记录真正发生的问题，不编造事故。

## 18. 测试与验收

### 18.1 静态合同

- Chart 版本被固定；
- 精简 values 明确关闭非目标组件；
- `/metrics` 不暴露 Secret；
- ServiceMonitor、PrometheusRule 和 Dashboard 可以渲染；
- monitoring 关闭时应用 Chart 仍可渲染；
- 告警规则和 Dashboard JSON/YAML 通过语法检查；
- Git 中不存在 Grafana 密码和导出的 Secret。

### 18.2 应用测试

- `/metrics` 返回 Prometheus 文本格式；
- 请求会增加 Counter；
- Histogram 产生 count/sum/bucket；
- 动态任务 ID 不进入 metric label；
- 原有 14 项测试继续通过。

### 18.3 集群验收

- Prometheus、Grafana、Alertmanager、Operator、kube-state-metrics 和 node-exporter Ready；
- Prometheus PVC Bound；
- Backend Target 为 UP；
- Prometheus 能查询应用和 Kubernetes 指标；
- Grafana 九个项目面板有真实数据或合理的零值；
- 三条项目告警规则处于已加载状态；
- 完成一次 `BackendTargetMissing` Firing -> Resolved：页面出现活动告警，恢复后活动告警消失且规则回到 Inactive；
- 演练后应用、Ingress、Pod rollout 和 MySQL 持久化数据正常；
- Jenkins 当前 Pipeline 仍然成功；
- 停止端口转发不会影响监控组件和业务工作负载。

只有以上验收通过后，才能把 README 和简历状态从“Phase 5 计划”改为“已实现 Prometheus/Grafana/Alertmanager 可观测性与告警闭环”。

## 19. 简历边界

完成后可以真实描述：

- 使用 kube-prometheus-stack 和 Prometheus Operator 在 k3d/Kubernetes 部署监控栈；
- 为 Flask 暴露 Prometheus 指标，使用 ServiceMonitor 自动发现；
- 使用 PromQL 和 Grafana 展示请求量、错误率、P95 延迟及 Kubernetes 工作负载状态；
- 使用 PrometheusRule 与 Alertmanager 完成真实告警触发和恢复演练；
- 通过 Helm、配置供应、资源限制、短期持久化和 Runbook 保证本地环境可重复。

不能描述：

- 生产级高可用 Prometheus；
- 邮件/短信/IM 值班通知；
- 日志和链路追踪平台；
- 多集群、长期存储或自动故障处置。

## 20. 完成定义

Phase 5 的完成标志不是“三个页面能够打开”，而是应用指标、Kubernetes 指标、Grafana Dashboard、PrometheusRule、Alertmanager Firing、规则恢复为 Inactive、持久化验证、自动测试和文档证据形成完整闭环。
