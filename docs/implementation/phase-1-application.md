# Phase 1：最小业务应用

## 1. 阶段目标

实现一个规模可控但功能完整的“运维任务清单”，为后续容器化、Kubernetes、CI/CD 和监控提供真实部署对象。应用必须具备页面、API、数据库读写、健康检查和自动测试。

## 2. 最终架构

```text
Browser
  -> Flask 静态页面与 REST API
  -> PyMySQL
  -> MySQL 8.4 容器（127.0.0.1:3306）
```

Flask 开发服务器运行在 WSL，MySQL 由单独的 Docker 命令启动。`/healthz` 只检查进程，`/readyz` 检查数据库连接。

## 3. 新增或修改的文件

- `app/backend/app.py`：Flask application factory、静态页面和健康端点。
- `app/backend/config.py`：从环境变量读取应用配置。
- `app/backend/db.py`：使用 PyMySQL 执行显式 SQL 和事务。
- `app/backend/routes.py`：任务 CRUD、输入校验和安全错误响应。
- `app/frontend/src/`：中文运维任务清单页面。
- `app/database/init.sql`：初始化 `ops_tasks` 数据表。
- `app/backend/tests/`：FakeDatabase 驱动的 pytest 单元测试。
- `scripts/start-phase1-mysql.sh`、`stop-phase1-mysql.sh`：数据库生命周期。
- `scripts/verify-phase1.sh`：Phase 1 综合验收。

## 4. 实际执行命令

```bash
cp .env.example .env
make phase1-db-up
make phase1-test
make phase1-verify
```

运行开发服务器时使用：

```bash
make phase1-run
```

## 5. 验证结果

14 个 pytest 测试全部通过。真实 MySQL CRUD 验收完成；停止 MySQL 后 `/healthz` 保持 200、`/readyz` 返回 503；重新启动 MySQL 后 readiness 恢复。Phase 1 最终验证提交为 `c8249d2`，并已推送到 GitHub `main`。

## 6. 简历能力映射

- Flask REST API 和基础前后端联调。
- PyMySQL、参数化 SQL、事务提交与回滚。
- MySQL 容器启动、初始化脚本和数据验证。
- liveness/readiness 健康检查设计。
- pytest 单元测试和 Bash 自动验收。

## 7. 与下一阶段的关系

Phase 2 将 Flask 开发服务器替换为 Gunicorn，把静态页面交给 Nginx，并通过 Docker Compose 将前端、后端和 MySQL 编排成可复现的三容器系统。
