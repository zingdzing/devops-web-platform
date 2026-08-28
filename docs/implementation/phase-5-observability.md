# Phase 5 可观测性与告警实施记录

## 1. 实施目标

Phase 5 在既有 Flask/MySQL、Kubernetes/Helm 和 Jenkins CI/CD 链路上增加一套资源受控的指标监控系统。完成标准不是“页面能够打开”，而是应用指标可抓取、Kubernetes 指标可查询、Dashboard 可自动供应、真实告警能够触发和恢复，并且演练后业务与 MySQL 数据保持正常。

本阶段不包含生产级高可用、邮件/短信/IM 通知、日志平台、链路追踪、多集群或长期存储。

## 2. 实测环境

| 组件 | 实测版本或配置 |
|---|---|
| k3d | `v5.9.0` |
| K3s/Kubernetes | `v1.36.1+k3s1`，单节点 |
| Helm | `v4.2.0` |
| kube-prometheus-stack | Chart `87.21.0`，Helm Revision `3`，状态 `deployed` |
| Prometheus | `v3.13.1-distroless`，保留 2 天，2 Gi PVC |
| Alertmanager | `v0.33.1`，保留 24 小时，1 Gi PVC |
| Grafana | `13.1.1` |
| Prometheus Operator | `v0.92.1` |
| 应用入口 | `http://localhost:8080` |
| 本机监控入口 | Prometheus `9090`、Grafana `3000`、Alertmanager `9093`，均只绑定 `127.0.0.1` |

Grafana 管理员密码由操作者交互创建在 `monitoring/grafana-admin` Secret 中。本仓库不保存密码、Secret 导出、PAT 或 kubeconfig。

## 3. 实现的数据流

```text
Flask /metrics -> backend Service -> ServiceMonitor
                -> Prometheus Operator -> Prometheus TSDB/PVC

kube-state-metrics + kubelet/cAdvisor + node-exporter
                -> Prometheus -> PromQL -> Grafana Dashboard
                              -> PrometheusRule -> Alertmanager
```

- Flask 使用 `prometheus-client` 输出请求 Counter、请求耗时 Histogram 和构建信息 Gauge。
- 指标标签只包含方法、路由模板和状态码；动态任务 ID 不进入标签，避免高基数。
- 应用 Chart 默认 `monitoring.enabled=false`，Phase 5/Jenkins 部署显式启用，以保持早期 Compose/Helm 场景可用。
- ServiceMonitor 通过 `release=kube-prometheus-stack` 被 Operator 发现，每 30 秒抓取 `/metrics`。
- Grafana Dashboard 以带 `grafana_dashboard=1` 标签的 ConfigMap 供应，不需要手工导入 JSON。

## 4. Dashboard 与告警

项目 Dashboard 共九个面板：Backend Target、请求速率、5xx 错误率、P95 延迟、Deployment 副本、Pod Ready、容器重启、Pod CPU 和 Pod 内存。

PrometheusRule 包含三条规则：

| 告警 | 条件 | 持续时间 |
|---|---|---|
| `BackendTargetMissing` | backend Target 不再为 UP | 1 分钟 |
| `DeploymentReplicasUnavailable` | frontend/backend 可用副本少于期望副本 | 1 分钟 |
| `ContainerRestartingFrequently` | 10 分钟内容器重启至少 3 次 | 1 分钟 |

## 5. 部署与权限边界

`make phase5-install` 安装固定版本的精简 kube-prometheus-stack。精简项包括关闭上游默认 Dashboard/规则和非目标控制面组件，保留 Prometheus、Alertmanager、Grafana、Operator、kube-state-metrics 和 node-exporter。监控 Service 不使用 Ingress、NodePort 或 LoadBalancer。

Jenkins 不负责安装 Operator、CRD 或整个监控栈。Pipeline 只在现有 `devops-platform` namespace 中随应用 Chart 更新 ServiceMonitor、PrometheusRule 和 Dashboard ConfigMap。`jenkins-deployer` 可以管理这三类 namespaced 资源，但不能读取 `monitoring` namespace Secret；没有为了 Phase 5 授予 cluster-admin。

## 6. 真实告警与恢复验收

`make phase5-verify` 已连续执行三次并通过。每次脚本都会检查八类真实指标，创建持久化任务，把 backend 从 1 个副本缩容到 0，等待 Prometheus 和 Alertmanager 出现真实告警，再恢复副本并证明规则恢复。

| 轮次 | Firing（UTC） | Resolved（UTC） | 持久化任务 ID | MySQL PVC UID 前缀 |
|---|---|---|---|---|
| 1 | `2026-08-28T03:31:59Z` | `2026-08-28T03:32:57Z` | `18` | `56ff847d` |
| 2 | `2026-08-28T03:35:30Z` | `2026-08-28T03:36:57Z` | `20` | `56ff847d` |
| 3 | `2026-08-28T03:49:57Z` | `2026-08-28T03:51:28Z` | `22` | `56ff847d` |

三次验收均确认：

- backend Target 初始为 UP，三条规则健康且非 Firing；
- `BackendTargetMissing` 进入 Prometheus Firing，并作为活动告警出现在 Alertmanager；
- 恢复 backend 后 Target 回到 UP，规则回到 Inactive，Alertmanager 活动告警消失；
- `/healthz`、`/readyz` 和 CRUD 恢复正常；
- ID 18、20、22 的任务在演练后仍存在并更新为 `completed`；
- MySQL PVC UID 未变化，验收临时端口转发均已退出。

## 7. Jenkins 连续性

Phase 5 把 19 项 pytest、监控 Chart 合同和 CR 渲染检查接入既有九阶段流水线。首次运行在 Quality Check 暴露 Jenkins 环境没有 Helm 官方仓库配置；修复后脚本会准备固定的 `prometheus-community` 仓库并有界重试。

2026-08-28，手工 Jenkins Build `#13`、`#14` 对提交 `8dd041e9229f...` 九阶段全部成功，证明修复后的质量门禁、镜像构建、推送、Helm 部署和入口 Smoke Test 正常。最终 Phase 5 文档提交仍需再运行一次 Jenkins 作为发布验收。

## 8. 资源边界与限制

- Prometheus、Alertmanager、Grafana 都是单实例；故障时可能中断，不是高可用。
- PVC 使用本地 `local-path`；删除 k3d cluster 会丢失监控历史和业务数据库数据。
- 监控保留时间短，适合本地演示，不适合生产容量和长期审计。
- Alertmanager 页面展示真实告警，但没有连接个人邮箱、短信或外部聊天软件。
- Grafana/Prometheus/Alertmanager 只通过临时 loopback port-forward 访问；停止转发不影响集群内监控。
- 监控安装需要管理员身份创建 CRD、ClusterRole 和 Webhook；Jenkins 日常发布仍保持 namespace 级权限。

## 9. 简历可用事实

可以真实描述：使用 kube-prometheus-stack/Prometheus Operator 部署监控栈，为 Flask 暴露低基数指标并通过 ServiceMonitor 自动发现；使用 PromQL 和 Grafana 展示应用及 Kubernetes 指标；使用 PrometheusRule 与 Alertmanager 完成真实 Firing-to-Resolved 告警演练；通过 Helm、PVC、Jenkins 质量门禁和 Runbook 保证本地环境可重复。

不能描述为生产级高可用监控、外部值班通知、日志/链路平台、多集群或长期存储。
