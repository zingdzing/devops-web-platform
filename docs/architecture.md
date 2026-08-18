# Architecture

## Request flow

1. 浏览器通过 Nginx Ingress 访问系统。
2. `/` 路由到 Nginx 静态前端。
3. `/api` 路由到 Flask 后端。
4. Flask 读写 MySQL。
5. `/healthz` 表示进程存活，`/readyz` 同时验证数据库连接。

## Release flow

1. 开发者将变更推送到 GitHub。
2. Jenkins 检出指定提交并执行 pytest。
3. 测试通过后构建带 Git 短提交号和构建号的镜像。
4. Jenkins 将镜像推送至 Docker Hub。
5. `helm lint` 和 `helm template` 通过后执行升级。
6. Jenkins 等待滚动发布并执行 HTTP Smoke Test。
7. 验证失败时停止流水线，由操作者依据 Runbook 执行 Helm 回滚。

## Monitoring flow

Prometheus 采集 Kubernetes 和 Flask 指标，Grafana 展示状态，Alertmanager 接收三条可演练告警。监控阶段完成前，不在 README 中宣称监控已经实现。
