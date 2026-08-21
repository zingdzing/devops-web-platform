# Phase 4 独立技术审查

## 审查范围与结论

本审查以只读方式检查 Jenkinsfile、CI 脚本、RBAC、Jenkins 持久化、凭据边界、Helm/Kubernetes 现场状态、自动验收、文档和 Git 状态。审查未读取密码、PAT、token、kubeconfig 内容或 Kubernetes Secret 值。

结论：项目的九阶段 CI/CD 链路真实可运行，技术密度适合初级 DevOps 简历项目；没有 P0。初次审查提出 3 个 P1、6 个 P2 和 2 个 P3，发布阻断项已全部处理，其余限制已修正或明确接受。

## P1 处置

1. **Poll SCM 未验收**：已处理。Build `#6` 与 `#7` 均记录 `SCMTriggerCause`；其中 `#7` 对提交 `e82f13f33f25...` 九阶段全部成功。
2. **`phase4-verify` 依赖易失 `/tmp` ID**：已处理。脚本改为从 `/api/items` 按唯一标题发现持久化记录，并在 Runbook 与合同中固定该行为。
3. **发布入口仍停留在 Phase 3**：已处理。README、架构、部署边界与实施记录更新为已实现 Phase 4，并保留 Phase 5 为计划。

## P2/P3 处置

- Jenkins 重启验收已扩展到 Job、构建历史、管理员用户、两个 Credential ID 与业务数据，不读取凭据值。
- 验收脚本固定管理员 context 为 `k3d-devops-platform`，不会自动切换集群。
- Runbook 默认路径改为普通克隆路径 `~/projects/devops-web-platform`。
- 文档明确：CLI 只注入镜像参数，但 Helm 会应用受信任 `main` 中的完整 Chart。
- JUnit 报告缺失会令 Pipeline 失败；Python 依赖重试表述已与实际实现一致。
- 两个凭据仍位于 System / Global store：为降低个人实验配置复杂度而接受，生产/共享 Controller 应使用 Folder 级凭据或独立 Controller。
- `plugins.txt` 固定插件集合但未逐项固定版本：本阶段接受，生产可复现构建应锁定插件版本。
- Docker Socket 与 namespace 内 Helm Secret 权限风险已在 README、实施记录和 Runbook 中披露。

## 审查后新增故障与回归

Build `#6` 暴露 rollout 后枚举终止中旧 Pod 导致的竞态误报。修复保留 `kubectl rollout status` 可用性门禁，改为核对 Deployment template 的声明镜像；合同测试禁止恢复过渡期 Pod 枚举。受限 kubeconfig 的 `--verify-only` 运行和自动 Build `#7` 均验证修复有效。

## 最终验证基线

- Jenkins Build `#7`：`SUCCESS`，触发原因 `SCMTriggerCause`；
- pytest：14 项通过；
- Helm：Revision 16，`deployed`；
- frontend/backend Deployment 与 MySQL StatefulSet：均 `1/1 Ready`；
- 两个 Docker Hub 镜像使用同一不可变 Git 标签；
- 健康、就绪、API 和数据库持久化标记通过；
- Phase 4 contract、ShellCheck、Helm 检查和 Git 差异检查作为最终发布门禁重新执行。

总体评价：项目没有用工具数量代替工程闭环，能够在面试中解释触发、凭据、不可变镜像、RBAC、Helm 发布、健康检查、持久化、失败证据和竞态修复，符合用户“先做出完整项目、复杂度适中、后续再按路线学习”的目标。
