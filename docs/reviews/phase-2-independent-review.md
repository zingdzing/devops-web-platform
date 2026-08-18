# Phase 2 独立技术审查

## 审查信息

- 日期：2026-08-18
- 对象：`phase2-containerization` 分支
- 范围：Dockerfile、Nginx、Docker Compose、自动验收、Makefile、README、架构与排错记录
- 方法：由独立子代理只读检查实现、文档和运行态，主执行者逐项复现并处理结论

## 总体结论

审查没有发现 P0 或 P1 阻塞问题。项目规模适中，三容器职责清楚，符合初学者 DevOps 简历项目的定位。审查确认前后端非 root、只有 Nginx 绑定 `127.0.0.1:8080`、三个服务健康，并认可不在 Phase 2 继续增加 Kubernetes、Jenkins 或监控工具。

## 发现与处理

### 1. Compose healthy 不等于业务 ready

旧 MySQL 检查使用 `mysqladmin ping`，错误密码仍返回 0；后端容器健康检查按设计只验证 `/healthz`。

处理：MySQL 改为鉴权执行 `SELECT 1`，`make phase2-up` 在 `--wait` 后额外验证 `/readyz`。保留 `/healthz` 的进程存活语义，供后续 Kubernetes liveness 使用。

### 2. 前置失败可能触发有副作用的 cleanup

处理：前置条件检查完成后才注册 EXIT trap，并只在验收脚本主动停止 MySQL 时恢复数据库。

### 3. 环境检查遗漏 curl

处理：`scripts/check-prerequisites.sh` 增加 curl，环境检查从 15 项变为 16 项；README 明确列出 Bash、curl、Python 3 和 Docker Compose。

### 4. 构建上下文检查范围不足

处理：前后端 `.dockerignore` 改为默认拒绝，只允许 Dockerfile 实际需要的源码和配置；验收脚本检查两份规则的首个有效条目均为 `*`。

### 5. 网络隔离表述强于单网络拓扑

处理：保持一个项目专用 Compose 网络以控制入门项目复杂度，文档收窄为“后端和数据库不发布宿主机端口、通过项目专用网络通信”，不宣称 frontend 在服务间网络层无法连接 MySQL。

### 6. 页面仍显示 Phase 1

处理：页面 meta、页眉、介绍和页脚更新为 Phase 2 容器化技术链路。

## 修正后验证

- 缺少 `.env` 时验收脚本立即失败，MySQL 状态不变。
- 错误密码执行 `SELECT 1` 返回失败。
- `make check` 的 16 项检查全部通过并包含 curl。
- 14 个 pytest 测试全部通过。
- `make phase2-up` 验证 readiness 成功。
- 页面返回 Phase 2 标识。
- `make phase2-verify` 完成 CRUD、故障恢复、非 root、端口与持久化验收。

## 接受的残余风险

- 镜像固定版本标签但未固定 digest，Python 传递依赖未使用哈希锁文件；进入 CI/CD 阶段再增强供应链锁定。
- `.env` 会出现在本地 Docker 配置中，适合个人实验，不适合生产；生产环境应使用 Secret 管理。
- 当前没有 TLS、用户认证、资源限制和数据库备份，这些不属于 Phase 2 范围。
- 命名卷提供持久化但不等同于备份，执行 `down --volumes` 后无法恢复。
- 内置敏感信息扫描只覆盖常见特征，不替代专业凭据扫描器。
