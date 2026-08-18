# Deployment boundary

部署内容按验证顺序逐步加入：

1. `compose/`：已实现本地 Nginx、Gunicorn/Flask 和 MySQL 联调。
2. `helm/`：后续实现 Kubernetes Deployment、StatefulSet、Service、Ingress、PVC、ConfigMap 和 Secret 模板。
3. `monitoring/`：后续实现 kube-prometheus-stack values、PrometheusRule 和 Grafana Dashboard。

## Phase 2 操作命令

首次运行：

```bash
cp .env.example .env
make phase2-up
```

查看服务日志：

```bash
make phase2-logs
```

执行完整验收：

```bash
make phase2-verify
```

停止容器但保留 MySQL 数据：

```bash
make phase2-down
```

## 数据安全提示

正常停止不要执行 `docker compose down --volumes`。`--volumes` 会删除 `devops-web-platform_mysql-data` 命名卷，其中的本地任务数据无法通过普通容器重启恢复。

`.env` 被 Git 忽略，只用于本地配置。不要把真实密码、Token、私钥、验证码或恢复码写入 Compose 文件、Dockerfile 或 Git 仓库。
