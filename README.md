# DevOps Web Platform

基于 Kubernetes 的 Web 应用自动化部署与监控平台，是一个面向 DevOps 初级岗位的个人实践项目。项目目标不是堆叠工具，而是用一条可以运行、验证、排错和复现的完整链路串联常见 DevOps 技能。

## 当前状态

**Phase 2：容器化与本地多容器联调。**

已实现“运维任务清单”的三容器版本：非特权 Nginx 提供静态页面并反向代理 API，Gunicorn 运行 Flask 后端，MySQL 8.4 保存业务数据。Docker Compose 负责服务发现、健康依赖、网络和命名卷，自动验收覆盖 CRUD、非 root 运行、端口边界、数据库故障恢复与数据持久化。

Kubernetes、Helm、Jenkins 和监控仍属于后续阶段，当前文档不把它们描述为已完成能力。

## Phase 2 快速启动

前置条件是 WSL Ubuntu、Git、Bash、curl、Python 3、Docker Compose 和正在运行的 Docker Desktop。在 WSL 中执行：

```bash
git clone git@github.com:zingdzing/devops-web-platform.git
cd devops-web-platform
cp .env.example .env
make phase2-up
```

浏览器访问 <http://127.0.0.1:8080>。

`.env` 只用于本地运行，已被 Git 忽略，不能提交到仓库。正常停止且保留 MySQL 数据：

```bash
make phase2-down
```

## 自动验收

```bash
make phase2-verify
```

该命令会：

1. 验证 Compose 配置并构建两个应用镜像。
2. 等待 Nginx、Flask 和 MySQL 全部健康。
3. 通过 Nginx 完成任务新增、查询、修改和删除。
4. 检查前后端非 root，后端和 MySQL 没有宿主机端口。
5. 停止 MySQL，确认 `/healthz` 为 200、`/readyz` 和业务接口为 503。
6. 恢复 MySQL，确认 readiness 自动恢复。
7. 重建容器，确认命名卷中的数据仍然存在。
8. 检查 Git 跟踪文件中没有常见 Token 或私钥特征。

## Phase 2 请求流

```text
Browser
  -> 127.0.0.1:8080
  -> Nginx frontend
  -> Gunicorn/Flask backend
  -> MySQL
  -> mysql-data named volume
```

- `/healthz`：只表示 Flask 进程可以响应，不依赖 MySQL。
- `/readyz`：执行真实数据库连接检查；MySQL 不可用时返回 HTTP 503。
- `/api/items`：提供运维任务 CRUD。

## 常用命令

```bash
make help
make check
make phase2-up
make phase2-logs
make phase2-verify
make phase2-down
```

## 技术栈

- Git、GitHub、SSH、2FA
- Python 3.14、Flask 3.1、PyMySQL、pytest
- Gunicorn 26
- Nginx unprivileged 1.28
- MySQL 8.4 LTS
- Docker、Docker Compose、Dockerfile、多阶段构建
- Bash、ShellCheck、Makefile
- k3d、Kubernetes、Helm（Phase 3 计划）
- Jenkins Pipeline（Phase 4 计划）
- Prometheus、Grafana、Alertmanager（Phase 5 计划）

## 实施路线

1. Phase 0：环境准备、仓库初始化、先决条件检查。✅
2. Phase 1：静态前端、Flask API、MySQL 初始化与单元测试。✅
3. Phase 2：Dockerfile、Docker Compose、本地多容器联调。✅
4. Phase 3：k3d 集群、Nginx Ingress、Helm Chart 与持久化。
5. Phase 4：Jenkins 测试、构建、推送、部署和验证流水线。
6. Phase 5：Prometheus 指标、Grafana 仪表盘和 Alertmanager 告警。
7. Phase 6：Pod 自愈、失败发布回滚、Runbook 与复盘。

## 项目记录

- `docs/implementation/`：每个阶段的目标、架构、命令和验证证据。
- `docs/troubleshooting/`：实际问题、根因、解决办法和预防措施。
- `docs/superpowers/specs/`：阶段设计。
- `docs/superpowers/plans/`：可执行实施计划。

## 安全规则

- 不提交 `.env`、真实密码、Token、恢复码、私钥或 kubeconfig。
- `.env.example` 只包含本地不可用于真实部署的示例值。
- SQL 使用参数绑定，不拼接用户输入。
- 前端和后端容器以非 root 用户运行。
- 只有 Nginx 绑定 `127.0.0.1:8080`，后端和 MySQL 保持内部访问。
- 本地实验使用 Compose 环境变量；生产环境应改用 Docker Secrets 或 Kubernetes Secret。
- 如果凭据曾进入 Git 历史，立即吊销并重新生成。

## 项目原则

项目只记录经过实际验证的能力。第一版不加入 Terraform、Ansible、Argo CD、Harbor、ELK、Service Mesh 或多集群，以保证每个进入仓库的组件都能够解释和排错。
