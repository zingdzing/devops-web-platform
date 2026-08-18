# Phase 2：容器化与本地多容器联调

## 1. 阶段目标

将 Phase 1 应用改造成无需宿主机 Python、Flask、Gunicorn、Nginx 或 MySQL 安装即可运行的三容器系统，并自动验证安全边界、故障恢复和数据持久化。

## 2. 最终架构

```text
Browser
  -> 127.0.0.1:8080
  -> 非特权 Nginx frontend（UID 101）
  -> Gunicorn + Flask backend（UID 10001）
  -> MySQL 8.4.11
  -> devops-web-platform_mysql-data 命名卷
```

三个服务通过 `app-network` 通信。只有 Nginx 映射宿主机端口；后端和 MySQL 的 `HostConfig.PortBindings` 均为 `{}`。

## 3. 新增或修改的文件

- `app/backend/Dockerfile`：Python 3.14.6 多阶段构建和非 root Gunicorn 运行时。
- `app/backend/.dockerignore`：排除测试、缓存和敏感文件形态。
- `app/backend/requirements-dev.txt`：把 pytest 与生产依赖分开。
- `app/frontend/Dockerfile`：固定版本非特权 Nginx 镜像。
- `app/frontend/nginx.conf`：静态文件和反向代理路由。
- `deploy/compose/docker-compose.yml`：三服务、健康依赖、网络和数据卷。
- `scripts/verify-phase2.sh`：构建、CRUD、故障、恢复、持久化和安全验收。
- `Makefile`：`phase2-up`、`phase2-down`、`phase2-logs`、`phase2-verify`。

## 4. 实际执行命令

```bash
cp .env.example .env
make phase2-up
make phase2-verify
make phase2-logs
make phase2-down
```

正常停止使用 `make phase2-down`，该命令保留命名卷。验收过程不会执行 `docker compose down --volumes`。

## 5. 验证结果

2026-08-18 连续执行两次 `make phase2-verify`，两次均退出 0。验证内容包括：Compose 配置解析、镜像构建、三服务 healthy、页面访问、完整 CRUD、前后端非 root、运行镜像不含 pytest、后端与 MySQL 无宿主机端口、MySQL 停机降级、数据库恢复，以及强制重建三个容器后的数据保留。

实际镜像版本为 Python 3.14.6 slim、Gunicorn 26.0.0、nginxinc/nginx-unprivileged 1.28.1 Alpine 和 MySQL 8.4.11。应用镜像名称分别为 `devops-web-platform-backend:phase2` 与 `devops-web-platform-frontend:phase2`。

## 6. 简历能力映射

- 编写前后端 Dockerfile 和 `.dockerignore`。
- 使用多阶段构建缩小后端运行环境职责。
- 以非 root 用户运行应用容器。
- 使用 Docker Compose 完成服务发现、健康依赖、网络隔离和数据持久化。
- 使用 Nginx 反向代理 Gunicorn/Flask。
- 编写可重复执行的故障注入与恢复验收脚本。

## 7. 与下一阶段的关系

Phase 3 将复用经过 Compose 验证的前后端镜像，把服务迁移到本地 k3d Kubernetes：前端与后端对应 Deployment/Service，MySQL 对应带持久化存储的工作负载。Phase 2 不提前加入 Kubernetes、Jenkins 或监控组件。
