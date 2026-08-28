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

## Implemented monitoring flow (Phase 5)

```text
Flask /metrics
  -> backend Service:http
  -> ServiceMonitor (devops-platform)
  -> Prometheus (monitoring, 2-day retention, 2 Gi PVC)

Kubernetes API -> kube-state-metrics --------------------^
node metrics   -> node-exporter -------------------------^

Prometheus -> Grafana provisioned Dashboard
PrometheusRule -> Prometheus rule evaluation -> Alertmanager
```

1. Flask 使用 Prometheus 文本端点暴露请求数、时延、任务状态、数据库连接结果和应用版本等低基数指标，不包含任务标题、描述、密码或 Token。
2. 应用 Chart 中的 ServiceMonitor 通过明确 Namespace、Service 标签和命名端口发现 backend；Prometheus Target 已验证为 `UP`。
3. Grafana sidecar 从带约定标签的 ConfigMap 自动加载九面板 Dashboard，Datasource 指向集群内 Prometheus Service。
4. 三条 PrometheusRule 分别覆盖 backend Target 丢失、Deployment 可用副本不足和容器频繁重启，并路由给 Alertmanager。
5. `scripts/verify-phase5.sh` 会记录原副本数和 MySQL PVC UID，创建持久化任务后把 backend 缩为 0，等待 `BackendTargetMissing` 在 Prometheus 与 Alertmanager 变为 Firing；随后恢复副本、等待规则 Inactive/活动告警消失，并验证任务与 PVC 未丢失。
6. Prometheus、Grafana 和 Alertmanager 均不创建公网入口。运维访问使用绑定 `127.0.0.1` 的临时 `kubectl port-forward`，关闭终端后不影响集群内采集和告警计算。

监控栈采用同一官方 kube-prometheus-stack Chart 的精简配置：单副本、短保留和明确资源边界，关闭本地 k3d 不需要或噪声较大的组件。它覆盖完整学习链路，但不声称具备生产级高可用、长期存储、多集群或外部通知能力。

## Implemented failure-recovery flow (Phase 6)

```text
Jenkins RUN_FAILURE_DRILL=true + input approval by zing
  -> record healthy Helm/image/application/PVC/Prometheus baseline
  -> set nonexistent backend image
  -> Kubernetes ErrImagePull / ImagePullBackOff
  -> Helm --rollback-on-failure
  -> verify application/data/PVC/Prometheus recovery
  -> expected red build + whitelisted archived evidence
  -> RUN_FAILURE_DRILL=false normal green build
```

1. `RUN_FAILURE_DRILL` 是默认关闭的 Boolean 参数；Poll SCM 和普通构建不会进入演练，人工启用后仍需 Jenkins 用户 `zing` 二次批准。
2. 故障源仅为动态的 `failure-drill-${BUILD_NUMBER}-does-not-exist` backend 标签。Pipeline 不构建或推送该标签，也不删除 Release、Namespace、Secret、PVC 或数据库数据。
3. 演练前记录最后健康 Helm revision、frontend/backend 镜像、MySQL PVC 名称/UID、业务 API 和 Prometheus Target；preflight 失败时不修改集群。
4. Helm upgrade 使用 `--rollback-on-failure --wait=watcher --timeout 5m`。退出保护在异常路径再次检查健康状态，必要时按 baseline revision 执行有界 `helm rollback`。
5. 恢复验证覆盖工作负载 Ready、原健康镜像、health/readiness/CRUD、持久化任务、MySQL PVC UID、监控 Pods、Prometheus Target 和 critical 活动告警。
6. 成功恢复后 Jenkins 主动写入 `EXPECTED_DRILL_FAILURE` 并把构建标红，使故障演练在历史中清晰可见；真正的恢复异常使用 `RECOVERY_FAILURE`，两者不能只靠颜色判断。
7. Jenkins 在 `monitoring` Namespace 只具有 Pods/Services/Endpoints 观察和临时 Pod port-forward 权限，仍不能读取 monitoring Secret、修改资源或访问 Node。

Phase 6 采用单集群、单次错误镜像演练，适合个人简历项目展示发布保护和排障闭环。它没有覆盖节点故障、网络分区、数据库备份恢复、多副本高可用、跨集群或跨区域灾难恢复。
