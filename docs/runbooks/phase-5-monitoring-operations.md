# Phase 5 监控与告警 Runbook

本手册面向项目的本地 k3d 环境。默认刚打开 Ubuntu 终端，先执行：

```bash
cd ~/projects/devops-web-platform
```

不要把 Grafana 密码、Docker Hub PAT、Jenkins 密码、kubeconfig、`.env` 或 Kubernetes Secret 内容粘贴到命令记录、截图、Issue 或 Git。

## 1. 安装、升级与状态

首次安装前，交互创建 Grafana Secret：

```bash
make phase5-grafana-secret
make phase5-install
make phase5-status
```

后续使用仓库固定的 Chart 与 values 升级：

```bash
make phase5-contract
make phase5-install
make phase5-status
```

`make phase5-install` 只管理 `monitoring` namespace 的监控栈，不会重建业务 MySQL、Jenkins Home 或 Docker Hub 凭据。安装前仍应确认当前 context 是 `k3d-devops-platform`。

## 2. 安全访问三个页面

每个命令占用一个终端，并且只监听 `127.0.0.1`：

```bash
make phase5-prometheus
make phase5-grafana
make phase5-alertmanager
```

分别访问：

- Prometheus：<http://127.0.0.1:9090>
- Grafana：<http://127.0.0.1:3000>
- Alertmanager：<http://127.0.0.1:9093>

终端按 `Ctrl+C` 只停止本机转发，不会停止集群中的监控 Pod、抓取、告警计算或数据保存。端口占用时先关闭旧转发，不要改成 `0.0.0.0` 暴露页面。

## 3. Grafana 密码重置

忘记密码时不能从仓库找回明文。创建一个新的、至少 12 位且与其他账号不同的密码：

```bash
make phase5-grafana-secret
kubectl rollout restart deployment/kube-prometheus-stack-grafana -n monitoring
kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring --timeout=180s
```

重启 Grafana Deployment 会造成短暂页面不可用，但不会删除 Dashboard ConfigMap、Prometheus/Alertmanager 数据或业务数据。把新密码保存到个人密码管理器，不要打印或提交 Secret。

## 4. BackendTargetMissing

**影响：** Prometheus 无法抓取 backend；API、就绪检查和任务操作可能失败。

**确认：**

```bash
kubectl get deployment,pod,service,endpoints -n devops-platform
kubectl get servicemonitor,prometheusrule -n devops-platform
curl -i http://localhost:8080/healthz
curl -i http://localhost:8080/readyz
```

在 Prometheus Targets 页面筛选 `namespace="devops-platform"`，核对 `service="backend"`、抓取 URL和错误信息。

**可能原因：** backend 被缩容、Pod 不 Ready、Service selector/端口名不匹配、ServiceMonitor 标签/namespace selector 错误，或 `/metrics` 不可用。

**恢复：**

```bash
kubectl scale deployment/devops-platform-devops-web-platform-backend -n devops-platform --replicas=1
kubectl rollout status deployment/devops-platform-devops-web-platform-backend -n devops-platform --timeout=180s
```

若期望声明来自 Helm，应再检查 Jenkins/Helm revision，而不是长期依靠手工 scale。验证 Target 回到 UP、规则变为 Inactive、Alertmanager 活动告警消失，并检查 `/readyz`。

## 5. DeploymentReplicasUnavailable

**影响：** frontend/backend 可用副本少于声明副本，页面或 API 可能中断。

```bash
kubectl get deployment,replicaset,pod -n devops-platform
kubectl describe deployment -n devops-platform devops-platform-devops-web-platform-backend
kubectl get events -n devops-platform --sort-by=.lastTimestamp
```

检查镜像拉取、Probe、资源不足和 MySQL readiness。恢复后等待 rollout，再确认期望/可用副本一致。不要通过删除 PrometheusRule 消除告警。

## 6. ContainerRestartingFrequently

**影响：** 容器在 10 分钟内至少重启 3 次，可能存在配置、依赖、资源或程序故障。

```bash
kubectl get pod -n devops-platform
kubectl describe pod -n devops-platform <pod-name>
kubectl logs -n devops-platform <pod-name> --previous
kubectl get events -n devops-platform --sort-by=.lastTimestamp
```

先保留日志和事件，再根据退出码处理。不要为了让计数归零而删除监控数据或规则。

## 7. ServiceMonitor 未发现或 Rule 未加载

```bash
kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com
kubectl get servicemonitor,prometheusrule -n devops-platform --show-labels
kubectl get prometheus -n monitoring -o yaml
make phase5-contract
```

重点核对 `release=kube-prometheus-stack`、namespace selector、Service selector、命名端口 `http` 和 `/metrics`。Rule 页面没有项目规则时检查 PrometheusRule 标签和 Operator 日志。

## 8. Grafana 无数据

先在 Prometheus 执行 Dashboard 中同一 PromQL。Prometheus 有数据而 Grafana 没有时，检查 datasource UID `prometheus`、Dashboard ConfigMap 标签和 Grafana sidecar 日志：

```bash
kubectl get configmap -n devops-platform -l grafana_dashboard=1
kubectl logs -n monitoring deployment/kube-prometheus-stack-grafana -c grafana-sc-dashboard
```

请求速率和 P95 需要时间窗口内有流量；合理零值不是采集失败。

## 9. 告警不触发或不恢复

- 不触发：检查表达式当前值、规则 health、`for: 1m` 和 Prometheus 到 Alertmanager 的连接。
- 不恢复：先恢复 backend 和 `/readyz`，等待下一次抓取/规则评估；确认 Target UP 后再检查 Alertmanager。
- 不得删除 Rule、Alertmanager 数据或监控 PVC 来伪造 Resolved。

标准闭环验收：

```bash
make phase5-verify
```

脚本失败会尽力恢复 backend，并把不含 Secret 的诊断写入 `reports/phase5-diagnostics-*`。

## 10. 停止与卸载边界

停止三个端口转发不会影响任何集群数据。卸载监控 release 前先确认业务仍在独立 namespace：

```bash
helm uninstall kube-prometheus-stack -n monitoring
kubectl get deployment,statefulset,pvc -n devops-platform
docker volume inspect devops-platform-jenkins-home
```

卸载监控栈不应删除 `devops-platform` namespace、MySQL PVC 或 Jenkins Home。监控 PVC 可能被保留，删除它们会永久丢失本地 Prometheus/Alertmanager 历史；删除整个 k3d cluster 会同时丢失 local-path 监控和 MySQL 数据，因此不属于日常清理命令。
