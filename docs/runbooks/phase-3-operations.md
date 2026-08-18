# Phase 3 Kubernetes 运维 Runbook

## 适用范围

本 Runbook 用于本项目的本地 k3d/K3s 环境。默认 namespace 为 `devops-platform`，Helm release 和 k3d cluster 均为 `devops-platform`。

## 安全的日常操作

首次创建集群并部署：

```bash
cp .env.example .env
make phase3-cluster-create
make phase3-deploy
make phase3-verify
```

查看状态、日志和最近事件：

```bash
make phase3-status
make phase3-logs
kubectl get events -n devops-platform --sort-by=.lastTimestamp
```

检查一个 backend Pod：

```bash
PHASE3_BACKEND_POD="$(kubectl get pod -n devops-platform -l app.kubernetes.io/component=backend -o jsonpath='{.items[0].metadata.name}')"
kubectl describe pod -n devops-platform "$PHASE3_BACKEND_POD"
kubectl logs -n devops-platform "$PHASE3_BACKEND_POD"
```

查看 Helm 历史：

```bash
helm history devops-platform -n devops-platform
```

回滚到前一个 revision：

```bash
PHASE3_ROLLBACK_REVISION="$(helm history devops-platform -n devops-platform -o json | jq -r '.[-2].revision')"
helm rollback devops-platform "$PHASE3_ROLLBACK_REVISION" -n devops-platform --wait
make phase3-verify
```

停止整个本地 k3d cluster、释放 8080，并保留集群定义、release、Secret 和 PVC：

```bash
make phase3-stop
```

如果只是停止了 k3d cluster，可以重新启动并恢复应用：

```bash
k3d cluster start devops-platform
make phase3-deploy
```

## 故障：页面或 API 不可用

**影响：** 浏览器无法加载页面、CRUD 失败，或 `/readyz` 返回非 200。

**确认：**

```bash
curl -i http://localhost:8080/healthz
curl -i http://localhost:8080/readyz
make phase3-status
kubectl get endpoints -n devops-platform backend
kubectl get events -n devops-platform --sort-by=.lastTimestamp
```

**可能原因：** 集群停止、Ingress Controller 未就绪、backend NotReady、MySQL 未就绪、Secret 与既有数据库账号不一致，或 8080 被其他进程占用。

**恢复：** 先查看事件和 Pod 日志。集群停止时运行 `k3d cluster start devops-platform`；工作负载被缩容时运行 `make phase3-deploy`。不要在未确认数据边界前删除 PVC。

**验证：**

```bash
make phase3-verify
```

**升级条件：** Pod 反复重启、PVC 无法 Bound、MySQL 日志出现存储损坏，或恢复操作可能要求删除 PVC 时，应停止操作并先备份/保留现场。

## 破坏性操作：必须先理解后果

以下命令不属于日常快捷目标。

卸载 Helm release 会删除应用工作负载和 Service；Chart 的 retention policy 会尽量保留 PVC，但仍应先确认 PVC 状态：

```bash
helm uninstall devops-platform -n devops-platform
```

删除 PVC 会删除本地 MySQL 持久化声明及其数据，普通重建无法恢复：

```bash
kubectl delete pvc -n devops-platform mysql-data-devops-platform-devops-web-platform-mysql-0
```

删除 k3d cluster 会删除整个本地 Kubernetes 环境，并丢失该集群中的 local-path 存储数据：

```bash
k3d cluster delete devops-platform
```
