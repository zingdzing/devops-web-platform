# DevOps Web Platform

基于 Kubernetes 的 Web 应用自动化部署与监控平台，是一个面向 DevOps 初级岗位的个人实践项目。目标不是堆叠工具，而是用一条可以运行、验证、排错和复现的完整链路串联常见 DevOps 技能。

## 当前状态

**Phase 3：Kubernetes 编排与 Helm 标准化部署已完成。**

“运维任务清单”运行在本地 k3d/K3s 集群：F5 NGINX Ingress Controller 统一接收入口流量，Nginx frontend 与 Gunicorn/Flask backend 使用 Deployment/Service，MySQL 使用 StatefulSet、headless Service 和 1 Gi PVC。Helm 管理应用声明，自动验收覆盖 CRUD、非 root、Pod 自愈、数据库故障降级、恢复、PVC 持久化与重复升级。

Jenkins 自动发布属于 Phase 4，Prometheus/Grafana/Alertmanager 属于 Phase 5，目前不把它们描述为已完成能力。

## Phase 3 快速启动

前置条件：WSL Ubuntu、Git、Bash、curl、jq、Python 3、Docker、k3d、kubectl、Helm、ShellCheck、Make，以及正在运行的 Docker Desktop。在 WSL 中执行：

```bash
git clone git@github.com:zingdzing/devops-web-platform.git
cd devops-web-platform
cp .env.example .env
make phase3-cluster-create
make phase3-deploy
make phase3-verify
```

浏览器访问 <http://localhost:8080>。`.env` 只用于本地运行，已被 Git 忽略，不能提交到仓库。

## 自动验收

```bash
make phase3-verify
```

该命令会：

1. 检查集群、Ingress Controller、Helm release、工作负载、PVC 和端口暴露边界。
2. 通过 Ingress 完成任务新增、查询、修改和删除。
3. 删除 backend Pod，确认 Deployment 自动创建新 Pod。
4. 停止 MySQL，确认 Flask 存活但未就绪，Service 隔离 NotReady backend。
5. 恢复 MySQL，确认 readiness 自动恢复。
6. 删除 MySQL Pod，确认 StatefulSet 重建后 PVC 中的数据仍在。
7. 重复执行 Helm upgrade，并检查 Git 跟踪文件没有常见 Token、私钥或 Secret 文件。

## Phase 3 请求流

```text
Browser -> 127.0.0.1:8080 -> k3d load balancer
        -> F5 NGINX Ingress Controller -> Ingress
        -> frontend Service -> Nginx Deployment
        -> backend Service  -> Gunicorn/Flask Deployment
        -> MySQL headless Service -> StatefulSet -> PVC
```

- `/healthz`：只表示 Flask 进程可以响应，不依赖 MySQL。
- `/readyz`：执行真实数据库连接检查；MySQL 不可用时返回 HTTP 503，Pod 会从 Service 可用端点中移除。
- `/api/items`：提供运维任务 CRUD。

## 常用命令

```bash
make help
make check
make phase3-cluster-create
make phase3-manifests
make phase3-deploy
make phase3-status
make phase3-logs
make phase3-verify
make phase3-stop
```

## 技术栈

- Git、GitHub、SSH、2FA
- Python 3.14、Flask 3.1、PyMySQL、pytest、Gunicorn 26
- Nginx unprivileged 1.28、MySQL 8.4 LTS
- Docker、Docker Compose、Dockerfile、多阶段构建
- k3d 5.9、K3s/Kubernetes 1.36、kubectl、Helm 4
- F5 NGINX Ingress Controller 5.5
- Deployment、Service、Ingress、StatefulSet、ConfigMap、Secret、PVC、Probe
- Bash、ShellCheck、Makefile
- Jenkins Pipeline（Phase 4 计划）
- Prometheus、Grafana、Alertmanager（Phase 5 计划）

## 实施路线

1. Phase 0：环境准备、仓库初始化、先决条件检查。✅
2. Phase 1：静态前端、Flask API、MySQL 初始化与单元测试。✅
3. Phase 2：Dockerfile、Docker Compose、本地多容器联调。✅
4. Phase 3：k3d/K3s、NGINX Ingress、Helm Chart、自愈与持久化。✅
5. Phase 4：Jenkins 测试、构建、推送、部署和验证流水线。
6. Phase 5：Prometheus 指标、Grafana 仪表盘和 Alertmanager 告警。
7. Phase 6：失败发布回滚演练、Runbook 完善与项目复盘。

## 项目记录

- `docs/implementation/`：阶段目标、架构、命令和验证证据。
- `docs/troubleshooting/`：真实问题、根因、解决办法和预防措施。
- `docs/runbooks/`：安全的日常操作、故障确认和恢复步骤。
- `docs/superpowers/specs/`：阶段设计。
- `docs/superpowers/plans/`：可执行实施计划。

## 安全与限制

- 不提交 `.env`、真实密码、Token、恢复码、私钥、kubeconfig 或渲染后的 Secret。
- frontend/backend 以非 root 用户运行；应用 Service 不使用 NodePort 或 LoadBalancer。
- Secret 运行时从 `.env` 创建；生产环境应改用专门的密钥管理方案。
- 当前只有一个节点、一个 frontend、一个 backend 和一个 MySQL。它能演示 Pod 自愈，但不是零停机或生产级高可用。
- PVC 使用本地 `local-path`；删除整个 k3d cluster 会丢失该集群中的数据库数据。

## 项目原则

项目只记录经过实际验证的能力。第一版不加入 Terraform、Ansible、Argo CD、Harbor、ELK、Service Mesh 或多集群，以保证每个进入仓库的组件都能够解释和排错。
