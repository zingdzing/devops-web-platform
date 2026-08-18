# Phase 2 容器化与本地多容器联调设计

## 1. 阶段目标

阶段 2 将 Phase 1 中依赖 WSL 本地 Python 环境运行的应用，改造成可以通过 Docker Compose 一键构建、启动、验证和停止的三容器系统。

完成后，使用者只需要 Docker 和项目仓库，不需要在宿主机安装 Python、Flask、PyMySQL、Gunicorn、Nginx 或 MySQL。

本阶段同时开始长期保存项目搭建过程和真实排错记录，便于后续学习、复现和面试说明。

## 2. 与项目目标的匹配结论

该阶段满足以下约束：

- **简历价值明确**：提供 Dockerfile、Docker Compose、容器健康检查、内部网络、非 root 运行和数据持久化证据。
- **规模适中**：只有前端、后端、MySQL 三个容器，不加入镜像仓库、Kubernetes、Jenkins 或监控系统。
- **完整可验证**：覆盖镜像构建、服务启动、CRUD、数据库故障、恢复和数据持久化。
- **方便后续学习**：职责边界与 Phase 3 Kubernetes 中的前端 Deployment、后端 Deployment 和 MySQL StatefulSet 一一对应。

## 3. 方案选择

采用三个独立容器：

```text
Browser
  |
  | 127.0.0.1:8080
  v
Nginx frontend container
  |
  | /api, /healthz, /readyz
  v
Gunicorn + Flask backend container
  |
  | mysql:3306 on internal network
  v
MySQL 8.4 container
  |
  v
Named Docker volume
```

不采用以下方案：

- 单容器运行全部组件：职责混杂，无法展示服务发现、容器网络和独立健康检查。
- 直接进入 Kubernetes：问题定位跨度过大，不利于在进入编排层前验证镜像本身。
- 在 Phase 2 引入 Harbor、Jenkins 或云服务：超出本阶段目标。

## 4. 组件设计

### 4.1 前端容器

- 使用固定版本的非特权 Nginx Alpine 镜像。
- 复制 `app/frontend/src/` 静态文件。
- 监听容器端口 8080。
- 将 `/api/`、`/healthz` 和 `/readyz` 反向代理到 `backend:5000`。
- 以非 root 用户运行。
- 通过 Nginx 首页请求执行健康检查。

宿主机只映射该容器：`127.0.0.1:8080:8080`。

### 4.2 后端容器

- 使用固定 Python slim 基础镜像。
- 使用多阶段构建安装依赖，运行镜像不包含 pip 缓存、编译缓存和测试代码。
- 将运行依赖与开发测试依赖拆分：运行镜像包含 Flask、PyMySQL、Gunicorn；pytest 只用于开发和测试。
- Gunicorn 运行 Flask application factory，不使用 Flask 开发服务器。
- 创建固定 UID 的普通用户并以非 root 身份运行。
- 使用 Python 标准库请求 `/healthz` 作为容器健康检查，不额外安装 curl。
- 只通过 Compose 内部网络暴露 5000，不映射宿主机端口。

### 4.3 MySQL 容器

- 使用固定的 MySQL 8.4 LTS 镜像。
- 继续使用 `app/database/init.sql` 初始化 `ops_tasks` 表。
- 使用命名 Volume 保存 `/var/lib/mysql`。
- 使用 `mysqladmin ping` 和本地环境变量执行健康检查。
- 不映射宿主机 3306 端口，通过项目专用 Compose 网络访问。

### 4.4 Docker Compose

Compose 文件位于 `deploy/compose/docker-compose.yml`，包含：

- `frontend`、`backend`、`mysql` 三个服务。
- 一个显式内部网络 `app-network`。
- 一个命名数据卷 `mysql-data`。
- `mysql` 健康后启动 `backend`，`backend` 健康后启动 `frontend`。
- 后端运行时覆盖 `DB_HOST=mysql` 和 `DB_PORT=3306`。
- 密码从被 Git 忽略的根目录 `.env` 注入。
- 镜像使用本地可识别名称和明确的 Phase 2 标签，不使用部署意义上的 `latest` 标签。

## 5. 文件结构

```text
app/
├── backend/
│   ├── Dockerfile
│   ├── .dockerignore
│   ├── requirements.txt
│   └── requirements-dev.txt
└── frontend/
    ├── Dockerfile
    ├── .dockerignore
    ├── nginx.conf
    └── src/

deploy/compose/
└── docker-compose.yml

scripts/
└── verify-phase2.sh

docs/
├── implementation/
│   ├── phase-0-environment.md
│   ├── phase-1-application.md
│   └── phase-2-containers.md
└── troubleshooting/
    ├── phase-0-1.md
    └── phase-2-containers.md
```

## 6. 配置与安全边界

- `.env` 继续被 Git 忽略。
- `.env.example` 只保留不可用于真实部署的本地示例值。
- Dockerfile 不包含密码、Token 或 Docker Hub 凭据。
- `.dockerignore` 排除 `.git`、`.env`、虚拟环境、缓存、日志、测试报告和私钥形态文件。
- 前端和后端容器必须以非 root 用户运行。
- MySQL 密码在本地实验中通过 Compose 环境变量传入；文档明确说明生产环境应使用 Docker Secrets 或 Kubernetes Secret。
- 只有 Nginx 端口绑定宿主机，后端和 MySQL 保持内部访问。

## 7. 启动与请求流

1. `docker compose up -d --build` 构建并启动服务。
2. MySQL 初始化数据库并通过健康检查。
3. 后端解析 `mysql` 服务名并连接数据库。
4. Gunicorn 启动 Flask worker 并通过 `/healthz`。
5. Nginx 启动并提供静态页面。
6. 浏览器请求 `127.0.0.1:8080`。
7. JavaScript 使用相对 `/api/items` 路径。
8. Nginx 将请求转发给 `backend:5000`。
9. 后端读写 MySQL，响应经 Nginx 返回浏览器。

## 8. 故障与恢复行为

### MySQL 不可用

- 后端进程继续运行，`/healthz` 保持 200。
- `/readyz` 和依赖数据库的业务接口返回 503。
- 前端显示后端返回的安全错误消息。
- MySQL 恢复健康后，后端下一次请求自动重新连接，无需重启。

### 后端不可用

- Nginx 仍可提供静态页面。
- API 请求返回 502。
- Compose 状态显示后端 unhealthy 或 exited，日志用于定位原因。

### 容器重建

- 前端和后端容器不保存业务状态，可以安全重建。
- MySQL 容器重建后继续挂载命名 Volume，原有任务数据必须保留。
- 只有显式执行带 `--volumes` 的清理命令才会删除数据；验收脚本不得执行该操作。

## 9. 自动验收

新增 `make phase2-verify`，必须验证：

1. `docker compose config` 解析成功。
2. 两个应用镜像构建成功。
3. 三个服务进入 healthy 状态。
4. 前端首页可以通过 8080 访问。
5. 通过 Nginx 完成一次新增、查询、修改和删除。
6. 前端、后端以非 root 用户运行。
7. 停止 MySQL 后 `/healthz` 为 200、`/readyz` 为 503。
8. 恢复 MySQL 后 `/readyz` 回到 200。
9. 重建容器后预先写入的数据仍存在。
10. 仓库和构建上下文不包含 `.env`、私钥或 Token 形态内容。

## 10. 文档与问题记录

每个实施阶段保存一份搭建记录，包含：

- 阶段目标和架构。
- 新增文件及其职责。
- 实际执行命令。
- 验证结果和可观察证据。
- 与下一阶段的关系。

每个真实问题使用统一格式：

```text
现象
影响
证据
根本原因
解决办法
验证结果
预防措施
```

Phase 2 开始时先补录已经发生的 Phase 0/1 问题，包括 SSH Agent、Windows/WSL 文件权限、缺少 `.env`、ShellCheck 间接调用提示和跨 Shell 变量传递问题。记录不得包含密码、完整公钥、私钥或恢复码。

## 11. 完成标准

- 新环境按照 README 能通过一条 Compose 命令启动系统。
- 三个服务健康，页面 CRUD 可用。
- 前端和后端均为非 root。
- 只有前端端口对宿主机开放。
- MySQL 故障与恢复行为通过自动验收。
- 容器重建后业务数据保留。
- Phase 0、Phase 1、Phase 2 搭建记录齐全。
- 已发生的问题均记录原因、解决办法和验证结果。
- README 只描述经过实际验证的 Phase 2 能力。
- 所有变更通过检查并推送 GitHub。
