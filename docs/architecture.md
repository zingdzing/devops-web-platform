# Architecture

## Implemented request flow (Phase 3)

```text
Browser
  -> 127.0.0.1:8080
  -> k3d load balancer
  -> F5 NGINX Ingress Controller
  -> Ingress devops-platform-devops-web-platform (host: localhost)
     ├─ / -> Service devops-platform-devops-web-platform-frontend:8080
     │       -> Nginx frontend Deployment
     └─ /api, /healthz, /readyz -> Service backend:5000
                                      -> Gunicorn/Flask backend Deployment
                                      -> headless MySQL Service:3306
                                      -> MySQL StatefulSet
                                      -> 1 Gi local-path PVC
```

1. k3d 把宿主机 `127.0.0.1:8080` 映射到集群 load balancer 的 80 端口。
2. F5 NGINX Ingress Controller 监听 `nginx` IngressClass；k3s 默认 Traefik 已被禁用。
3. Ingress 按路径把静态页面交给 frontend，把 API 和健康端点直接交给 backend。
4. frontend 继续使用 Phase 2 的非特权 Nginx 镜像；backend 使用非 root Gunicorn/Flask 镜像。
5. backend 通过 `devops-platform-devops-web-platform-mysql` headless Service 连接 MySQL。
6. StatefulSet 给 MySQL 提供稳定名称，`volumeClaimTemplates` 创建并重新挂载 PVC。

应用 Service 均为 ClusterIP 或 headless，不使用 NodePort/LoadBalancer。frontend 和 backend 分别以 UID 101 与 UID 10001 运行。数据库 Secret 在部署时创建，Chart 只通过 `existingSecret` 引用它。

## Health and dependency behavior

- startup Probe 通过 `/healthz` 判断 backend 进程已启动。
- liveness Probe 通过 `/healthz` 判断 Flask/Gunicorn 是否仍可响应，不访问 MySQL。
- readiness Probe 通过 `/readyz` 执行真实数据库连接，超时为 5 秒，大于 PyMySQL 3 秒连接超时。
- MySQL 不可用时 backend 进程继续运行并返回 `/readyz=503`；Kubernetes 将 NotReady Pod 从 `backend` Service endpoints 中移除，Ingress 外部请求此时返回 503。
- MySQL 恢复后，下一次检查重新连接数据库，backend 无需重启即可恢复 Ready。

单副本 backend 被删除后，Deployment 会补建 Pod，但恢复窗口内会中断服务。这是自愈，不是零停机高可用。

## State and recreation

frontend/backend 是无状态 Deployment。MySQL 是单副本 StatefulSet，PVC 名称为 `mysql-data-devops-platform-devops-web-platform-mysql-0`，StorageClass 为 `local-path`，容量 1 Gi，PVC retention policy 对 scale/delete 均为 `Retain`。

MySQL Pod 删除和 StatefulSet 缩容不会删除 PVC，重建后数据仍在。`helm uninstall` 也不应被当作数据删除工具；显式删除 PVC 或整个 k3d cluster 会造成该本地数据丢失。

## Phase 2 relationship

Phase 3 复用 Phase 2 已验证的应用镜像和相对 URL。Compose DNS 名称 `backend` 也是 Nginx 配置中的明确契约，因此 Kubernetes 后端 Service 固定为 `backend`；项目专用 namespace 避免名称冲突。Compose 命名卷与 Kubernetes PVC 是两套独立的本地数据存储。

## Implemented release flow (Phase 4)

1. Jenkins 使用 `pollSCM('H/5 * * * *')` 发现 GitHub `main` 新提交，并验证工作区 HEAD 等于 `origin/main`。
2. Pipeline 执行 pytest、ShellCheck、Helm lint、清单和秘密形状门禁，JUnit 与诊断文件作为构建产物保存。
3. 测试通过后构建 frontend/backend 镜像，以 `git-<sha12>` 作为不可变标签，并写入 OCI revision label。
4. Jenkins 使用 `dockerhub-ci` 凭据把两个镜像推送到 Docker Hub。
5. Jenkins 使用 namespace 专用 `k3d-deployer-kubeconfig`，通过 Helm 应用受信任 `main` 中的完整 Chart；CLI 只注入两个镜像 repository/tag。
6. `kubectl rollout status` 证明新版工作负载可用，再核对 Deployment template 镜像、MySQL StatefulSet 和真实 Ingress 健康/API 路径。
7. Helm upgrade 自身失败时由 Helm 事务回滚；upgrade 成功后的 Smoke Test 失败会停止流水线并保留诊断，由 Runbook 指导人工确认 revision 后回滚。

Jenkins Controller 运行在本地 Docker 容器中，`127.0.0.1:8090` 只对宿主开放，Jenkins Home 使用 named volume 持久化。Docker Socket 允许构建镜像，也意味着较高宿主权限，因此只运行受信任的 `main`，不执行未知 Pull Request Jenkinsfile。

## Planned monitoring flow (Phase 5)

Prometheus 将采集 Kubernetes 和 Flask 指标，Grafana 展示状态，Alertmanager 接收可演练告警。监控阶段完成前，不宣称已实现可观测性平台。
