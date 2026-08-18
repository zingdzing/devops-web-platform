# Architecture

## Implemented request flow (Phase 1)

1. 浏览器从 Flask `/` 加载静态运维任务页面。
2. 页面通过同源 `/api/items` 调用 CRUD API。
3. Flask 校验 JSON 输入并调用数据库适配器。
4. PyMySQL 使用参数化 SQL 读写 MySQL `ops_tasks` 表。
5. `/healthz` 只检查应用进程；`/readyz` 同时验证数据库连接。

Phase 1 由 Flask 临时提供前端以避免额外 CORS 配置。Phase 2 改由 Nginx 提供前端，但保留相对 `/api` 路径，因此浏览器代码无需改写后端地址。

## Planned release flow

1. 开发者将变更推送到 GitHub。
2. Jenkins 检出指定提交并执行 pytest。
3. 测试通过后构建带 Git 短提交号和构建号的镜像。
4. Jenkins 将镜像推送至 Docker Hub。
5. `helm lint` 和 `helm template` 通过后执行升级。
6. Jenkins 等待滚动发布并执行 HTTP Smoke Test。
7. 验证失败时停止流水线，由操作者依据 Runbook 执行 Helm 回滚。

## Planned monitoring flow

Prometheus 采集 Kubernetes 和 Flask 指标，Grafana 展示状态，Alertmanager 接收三条可演练告警。监控阶段完成前，不在 README 中宣称监控已经实现。
