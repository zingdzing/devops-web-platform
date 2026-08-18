# Architecture

## Implemented request flow (Phase 2)

```text
Browser -> 127.0.0.1:8080 -> Nginx frontend -> Gunicorn/Flask backend -> MySQL -> mysql-data volume
```

1. 浏览器只访问绑定在 `127.0.0.1:8080` 的 Nginx。
2. Nginx 从 `/usr/share/nginx/html` 提供静态运维任务页面。
3. `/api/`、`/healthz` 和 `/readyz` 被代理到 Compose DNS 名称 `backend:5000`。
4. Gunicorn 启动两个 worker 并加载 Flask application factory `create_app()`。
5. Flask 通过 Compose DNS 名称 `mysql:3306` 连接 MySQL。
6. PyMySQL 使用参数化 SQL 读写 `ops_tasks` 表。
7. MySQL 数据保存在 `devops-web-platform_mysql-data` 命名卷中。

`backend` 和 `mysql` 不映射宿主机端口。Docker inspect 验证二者的 `HostConfig.PortBindings` 为 `{}`。Nginx 和 Flask 分别以 UID 101 与 UID 10001 运行。

## Health and dependency behavior

- MySQL 健康后，Compose 才启动 backend。
- backend 的 `/healthz` 健康后，Compose 才启动 frontend。
- `/healthz` 只检查 Flask/Gunicorn 进程，不访问 MySQL。
- `/readyz` 执行真实数据库连接检查。
- MySQL 停止时，Nginx 和 Gunicorn 继续运行；liveness 保持 200，readiness 与依赖数据库的 API 返回 503。
- MySQL 恢复后，下一次请求重新建立连接，无需重启 backend。

## State and recreation

frontend 和 backend 是无状态容器，可以安全重建。MySQL 容器重建后重新挂载命名卷，因此业务数据保留。普通的 `docker compose down` 不删除该卷；只有显式使用 `down --volumes` 才会删除本地数据库数据。

## Phase 1 relationship

Phase 1 由 Flask 开发服务器同时提供前端和 API。Phase 2 保留原有 Flask API、相对 `/api` 路径和健康端点，但把静态文件交给 Nginx，并用 Gunicorn 替换开发服务器。这样浏览器代码不需要写死后端地址。

## Planned release flow

1. 开发者将变更推送到 GitHub。
2. Jenkins 检出指定提交并执行 pytest。
3. 测试通过后构建带 Git 短提交号和构建号的镜像。
4. Jenkins 将镜像推送至 Docker Hub。
5. `helm lint` 和 `helm template` 通过后执行升级。
6. Jenkins 等待滚动发布并执行 HTTP Smoke Test。
7. 验证失败时停止流水线，由操作者依据 Runbook 执行 Helm 回滚。

该发布流属于后续阶段，Phase 2 尚未实现 Jenkins 或镜像推送。

## Planned monitoring flow

Prometheus 采集 Kubernetes 和 Flask 指标，Grafana 展示状态，Alertmanager 接收可演练告警。监控阶段完成前，不在 README 中宣称监控已经实现。
