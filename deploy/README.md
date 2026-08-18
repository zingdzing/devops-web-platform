# Deployment boundary

## 已实现的部署方式

### Docker Compose（Phase 2）

`compose/` 用于本地三容器联调：Nginx frontend、Gunicorn/Flask backend 和 MySQL。它证明应用镜像、服务发现、健康检查和命名卷可以工作，但不是当前 Phase 3 的默认入口。

### 应用 Helm Chart（Phase 3）

`helm/devops-web-platform/` 只管理业务 namespace 中的应用资源：

- frontend/backend Deployment 与 ClusterIP Service
- MySQL StatefulSet、headless Service 和 PVC
- ConfigMap、Ingress，以及对外部已有 Secret 的引用

Chart 不创建密码值，也不安装 Ingress Controller。部署脚本从被 Git 忽略的 `.env` 在运行时创建 Secret，再执行 Helm upgrade。

### Ingress 基础设施（Phase 3）

`k3d/cluster.yaml` 创建本地 K3s 集群并禁用自带 Traefik。`scripts/create-phase3-cluster.sh` 另行安装 F5 NGINX Ingress Controller。Controller 是集群入口基础设施；应用 Chart 中的 Ingress 只是路由规则，两者不是同一个资源。

## Phase 3 操作命令

```bash
install -m 600 .env.example .env
make phase3-cluster-create
make phase3-manifests
make phase3-deploy
make phase3-status
make phase3-logs
make phase3-verify
make phase3-stop
```

`make phase3-stop` 停止整个本地 k3d cluster，从而释放 8080；它不删除集群定义、Helm release、Secret 或 PVC。破坏性删除命令及后果见 `docs/runbooks/phase-3-operations.md`。

## 数据与密钥边界

- `.env` 被 Git 忽略，且部署前必须是 mode 600；不要写入真实线上凭据。
- 已有 MySQL PVC 时，部署脚本会拒绝数据库名、用户或密码变化；本 Chart 不实现在线凭据轮换。
- MySQL PVC 使用 `Retain` retention policy，普通 Pod 重建、缩容和 Helm upgrade 不会删除数据。
- 删除 PVC 或整个 k3d cluster 会丢失 local-path 数据。
- 不要把 `helm template --show-only ...secret...` 的输出保存并提交到仓库。

当前 Chart 的 backend Service 为了复用 Phase 2 Nginx 镜像而固定命名为 `backend`，因此约束为“一个 namespace 只安装一个 release”，不把它描述成通用多实例 Chart。

## 后续部署内容

`monitoring/` 将在 Phase 5 保存 kube-prometheus-stack values、PrometheusRule 和 Grafana Dashboard。Jenkins 发布流程属于 Phase 4，尚未实现。
