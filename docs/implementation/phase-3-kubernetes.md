# Phase 3：Kubernetes 编排与 Helm 标准化部署

## 1. 阶段目标

把 Phase 2 已验证的三容器应用迁移到本地 Kubernetes，并用 Helm 把部署配置模板化。范围保持为单节点、单副本的学习与简历项目，重点验证编排、服务发现、入口路由、健康探针、自愈和持久化，不把它包装成生产级高可用平台。

## 2. 最终架构

```text
Browser
  -> 127.0.0.1:8080
  -> k3d load balancer
  -> F5 NGINX Ingress Controller
  -> Ingress
     ├─ /              -> frontend Service -> Nginx Deployment
     └─ /api,/healthz,/readyz
                       -> backend Service  -> Gunicorn/Flask Deployment
                                               -> MySQL headless Service
                                               -> MySQL StatefulSet
                                               -> 1 Gi local-path PVC
```

本地集群由 k3d 5.9.0 创建，实际节点运行 `rancher/k3s:v1.36.1-k3s1`。kubectl 客户端为 1.36.1，Helm 为 4.2.0。k3s 自带 Traefik 被禁用，入口基础设施单独安装 F5 NGINX Ingress Controller Chart 2.6.4（Controller 5.5.4）。

## 3. 新增或修改的文件

- `deploy/k3d/cluster.yaml`：单节点 k3d 集群、8080 端口映射和 Traefik 禁用配置。
- `deploy/helm/devops-web-platform/`：应用 Helm Chart、values、JSON Schema 和 Kubernetes 模板。
- `scripts/create-phase3-cluster.sh`：创建集群并安装独立的 Ingress Controller。
- `scripts/deploy-phase3.sh`：构建镜像、导入 k3d、创建运行时 Secret 并执行 Helm 升级。
- `scripts/check-phase3-manifests.sh`：在部署前检查渲染清单、安全边界和敏感文件形态。
- `scripts/verify-phase3.sh`：CRUD、自愈、依赖降级、PVC 持久化和重复升级验收。
- `scripts/stop-phase3.sh`：停止 k3d cluster 并释放入口端口，但保留集群定义、Helm release、Secret 和 PVC。
- `Makefile`：统一 Phase 3 创建、部署、状态、日志、停止和验收入口。

## 4. 实际执行命令

```bash
install -m 600 .env.example .env
make phase3-cluster-create
make phase3-manifests
make phase3-deploy
make phase3-status
make phase3-verify
```

浏览器入口为 <http://localhost:8080>。日常停止使用 `make phase3-stop`；恢复时先运行 `make phase3-cluster-create`，再运行 `make phase3-deploy`。

## 5. 验证结果

2026-08-18，`make phase3-verify` 连续两次退出 0，重复 Helm upgrade 后 release 状态为 `deployed`；frontend/backend Deployment 和 MySQL StatefulSet 均为 `1/1 Ready`，PVC 为 `Bound`，Ingress 使用 `nginx` IngressClass 和 `localhost` Host。

自动验收通过 Ingress 完成 CRUD；删除 backend Pod 后，UID 从 `5897eb18` 变为 `78483083`，Deployment 自动补齐副本；MySQL 缩容为 0 时，backend 进程的 `/healthz` 保持 200，数据库就绪检查 `/readyz` 返回 503，Service 将 NotReady Pod 从端点中移除；MySQL 恢复后 readiness 自动恢复。删除 MySQL Pod 后，UID 从 `7deed554` 变为 `2f5049fd`，预先写入的记录仍可查询，证明 PVC 被重新挂载。

## 6. 简历能力映射

- 使用 k3d/K3s 搭建可重复创建的本地 Kubernetes 环境，并显式禁用默认 Traefik。
- 独立安装和验证 F5 NGINX Ingress Controller，通过 Ingress 统一暴露前端、API 与健康端点。
- 编写 Helm Chart，将 Deployment、Service、StatefulSet、ConfigMap、Ingress 和 PVC 声明模板化。
- 为容器配置资源 requests/limits、非 root 安全上下文以及 startup/readiness/liveness Probe。
- 使用 StatefulSet、headless Service 和 `volumeClaimTemplates` 管理 MySQL 稳定身份与持久化存储。
- 编写 Bash 自动验收，验证 Pod 自愈、依赖故障降级、数据持久化、重复 Helm 升级与敏感文件边界。

## 7. 限制与诚实边界

- 集群只有一个 k3d server 节点，各工作负载只有一个副本；Pod 可以自动恢复，但恢复期间会短暂不可用，不是零停机高可用。
- MySQL 是单副本，PVC 使用 k3s `local-path` StorageClass；它适合本机学习，不提供跨节点复制、备份或灾难恢复。
- `helm uninstall` 因 PVC retention policy 不主动删除声明，但删除整个 k3d 集群会丢失集群内 local-path 数据。
- Secret 在部署时从被 Git 忽略且权限为 600 的 `.env` 创建；已有 PVC 时会拒绝数据库身份变化，没有实现 Vault、External Secrets 或在线密钥轮换。
- backend Service 为复用已有 Nginx 镜像固定命名为 `backend`，因此当前 Chart 限定一个 namespace 一个 release。
- 应用镜像只导入本地 k3d，没有推送镜像仓库，也没有实现自动发布流水线。

## 8. 与 Phase 4 的关系

Phase 3 提供了可重复执行的 `helm lint`、清单检查、镜像构建、Helm upgrade 和 Smoke Test 接口。Phase 4 将把这些已验证的本地步骤编排进 Jenkins Pipeline，并增加按提交标识镜像、推送 Docker Hub、部署确认与失败停止；当前阶段不提前宣称 CI/CD 已完成。
