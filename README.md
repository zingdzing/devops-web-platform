# DevOps Web Platform

基于 Kubernetes 的 Web 应用自动化部署与监控平台，是一个面向 DevOps 初级岗位的个人实践项目。目标不是堆叠工具，而是用一条可以运行、验证、排错和复现的完整链路串联常见 DevOps 技能。

## 当前状态

**Phase 6：参数化失败发布、Helm 自动回滚与恢复验收闭环已完成。**

“运维任务清单”运行在本地 k3d/K3s 集群：F5 NGINX Ingress Controller 统一接收入口流量，Nginx frontend 与 Gunicorn/Flask backend 使用 Deployment/Service，MySQL 使用 StatefulSet、headless Service 和 1 Gi PVC。Helm 管理应用声明，Jenkins 轮询 GitHub `main`，自动测试、构建、检查、推送两个不可变 Docker Hub 镜像，随后部署到 Kubernetes 并执行真实入口冒烟测试。独立 `monitoring` Namespace 中的精简 kube-prometheus-stack 通过 ServiceMonitor 自动发现 Flask 指标，Grafana 展示项目 Dashboard，PrometheusRule 与 Alertmanager 构成告警闭环。

2026-08-28，Phase 5 验收脚本连续两次完成真实 `BackendTargetMissing` 告警触发和恢复，持久化任务与 MySQL PVC UID 在演练前后保持一致；Jenkins Build `#13`、`#14` 也在加入监控资源后十阶段全部成功。随后 Phase 6 Jenkins Build `#17` 用不存在的 backend 镜像触发真实拉取失败，Helm 自动回滚后应用、任务数据、MySQL PVC 与 Prometheus Target 均恢复；Build `#18` 关闭演练参数后正常阶段全绿。具体证据见 `docs/implementation/phase-6-failure-recovery.md`。

## 平台首次部署（Phase 3）

前置条件：WSL Ubuntu、Git、Bash、curl、jq、Python 3、Docker、k3d、kubectl、Helm、ShellCheck、Make，以及正在运行的 Docker Desktop。在 WSL 中执行：

```bash
git clone git@github.com:zingdzing/devops-web-platform.git
cd devops-web-platform
install -m 600 .env.example .env
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

Phase 4 已完成凭据配置的本地环境还可以执行：

```bash
make phase4-jenkins-up
make phase4-contract
make phase4-verify
```

向 GitHub `main` 推送提交后，Jenkins 按 `H/5` 轮询自动运行九阶段流水线；Jenkins 页面位于 <http://localhost:8090>。首次安装和凭据设置见 `docs/runbooks/phase-4-jenkins-operations.md`。

Phase 5 监控栈的安装、状态检查和真实告警验收：

```bash
make phase5-grafana-secret
make phase5-install
make phase5-status
make phase5-contract
make phase5-verify
```

Grafana、Prometheus 和 Alertmanager 只通过临时 localhost 端口转发访问，具体命令、密码轮换和故障恢复见 `docs/runbooks/phase-5-monitoring-operations.md`。

Phase 6 的静态安全合同和恢复后实时验收：

```bash
make phase6-contract
make phase6-verify
```

故障演练默认关闭，只能从 Jenkins `Build with Parameters` 手动勾选 `RUN_FAILURE_DRILL`，并由 `zing` 二次批准。红色 Build 只有同时满足 `EXPECTED_DRILL_FAILURE`、恢复报告字段全部为 true 且 `make phase6-verify` 通过时，才表示演练成功。操作与人工恢复步骤见 `docs/runbooks/phase-6-failure-release-recovery.md`。

## 应用请求流

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

## CI/CD 发布流

```text
GitHub main -> Jenkins Poll SCM -> pytest / ShellCheck / Helm checks
            -> build + verify frontend/backend images
            -> Docker Hub immutable git-<sha12> tags
            -> scoped kubeconfig -> Helm upgrade -> rollout -> smoke test
```

Docker Hub PAT 与 namespace 专用 kubeconfig 只由 Jenkins Credentials 注入。Pipeline 不读取根目录 `.env`，不创建数据库 Secret，也不删除 namespace、PVC 或 Helm release。

## 监控与告警流

```text
Flask /metrics -> Backend Service -> ServiceMonitor -> Prometheus
Kubernetes API -> kube-state-metrics --------------------^
Prometheus -> Grafana Dashboard
PrometheusRule -> Prometheus -> Alertmanager -> 本机安全访问页面
```

应用暴露请求、时延、任务、数据库连接和版本等低基数指标。三条项目告警覆盖 backend 目标丢失、Deployment 副本不可用和容器频繁重启；自动验收会真实缩容 backend、观察 Firing、恢复副本并等待规则回到 Inactive，而不是删除规则伪造恢复。

## 失败发布与恢复流

```text
Jenkins RUN_FAILURE_DRILL=true + 人工批准
  -> 发布不存在的 backend 镜像
  -> Kubernetes ErrImagePull / ImagePullBackOff
  -> Helm rollback-on-failure
  -> 应用、任务数据、PVC 与 Prometheus 恢复验证
  -> EXPECTED_DRILL_FAILURE 红色证据构建
  -> RUN_FAILURE_DRILL=false 正常绿色构建
```

演练不删除 Release、Namespace、Secret 或 PVC，不修改数据库密码，也不会由 Poll SCM 自动触发。它用于展示受控故障注入、证据采集、回滚和 Runbook 能力，不是生产级混沌工程或灾难恢复。

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
make phase4-jenkins-up
make phase4-contract
make phase4-verify
make phase4-jenkins-stop
make phase5-install
make phase5-status
make phase5-contract
make phase5-verify
make phase6-contract
make phase6-verify
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
- Jenkins 2.568、Declarative Pipeline、Credentials、JUnit、Poll SCM
- kube-prometheus-stack 87.21.0、Prometheus 3.13、Prometheus Operator 0.92、Grafana 13.1、Alertmanager 0.33
- ServiceMonitor、PrometheusRule、PromQL、kube-state-metrics、node-exporter

## 实施路线

1. Phase 0：环境准备、仓库初始化、先决条件检查。✅
2. Phase 1：静态前端、Flask API、MySQL 初始化与单元测试。✅
3. Phase 2：Dockerfile、Docker Compose、本地多容器联调。✅
4. Phase 3：k3d/K3s、NGINX Ingress、Helm Chart、自愈与持久化。✅
5. Phase 4：Jenkins 测试、构建、推送、部署和验证流水线。✅
6. Phase 5：Prometheus 指标、Grafana 仪表盘和 Alertmanager 告警。✅
7. Phase 6：失败发布回滚演练、Runbook 完善与项目复盘。✅

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
- 为保护已有 MySQL PVC，当前阶段不支持直接修改数据库名、用户或密码；部署脚本会拒绝这类变化。
- 当前只有一个节点、一个 frontend、一个 backend 和一个 MySQL。它能演示 Pod 自愈，但不是零停机或生产级高可用。
- PVC 使用本地 `local-path`；删除整个 k3d cluster 会丢失该集群中的数据库数据。
- Jenkins 仅绑定本机，但挂载 Docker Socket，适合受信任的个人实验环境，不是生产级隔离。
- 两个 Jenkins 凭据当前位于 System / Global store；生产或多人共享环境应改为 Folder 级凭据或独立 Controller。
- `plugins.txt` 固定插件集合但未逐项固定插件版本；Jenkins 基础镜像已固定，完整可复现的生产方案还应锁定插件版本。
- 监控组件均为单副本，Prometheus/Alertmanager 使用短期 local-path PVC；适合本机学习和演练，不是生产级高可用或跨集群存储。
- 当前未连接个人邮箱或外部聊天软件；告警在 Alertmanager 页面内验收，避免为简历项目引入额外账号、密钥和通知噪声。
- Phase 6 只在本机非生产 k3d 集群运行，并要求人工参数和二次批准；它验证的是单次失败发布恢复，不等同于生产级混沌工程、数据库备份恢复、跨区域容灾或零停机高可用。

## 项目原则

项目只记录经过实际验证的能力。第一版不加入 Terraform、Ansible、Argo CD、Harbor、ELK、Service Mesh 或多集群，以保证每个进入仓库的组件都能够解释和排错。
