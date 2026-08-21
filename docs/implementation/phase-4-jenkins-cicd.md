# Phase 4 Jenkins CI/CD 实施与验收记录

## 1. 实施目标

Phase 4 在 Phase 3 的 k3d/Kubernetes/Helm 平台上加入本地 Jenkins CI/CD。流水线把 GitHub `main` 提交转换为两个可追踪的 Docker Hub 镜像，通过 Helm 更新现有应用，并从 NGINX Ingress 的真实入口验证页面、API 和 MySQL 数据链路。

本阶段没有增加业务功能，也没有重建数据库。Jenkins 不读取根目录 `.env`，不创建或修改数据库 Secret，不删除 PVC、namespace 或 Helm release。

## 2. 已验证运行环境

| 组件 | 实测版本或配置 |
|---|---|
| Jenkins | `2.568.1`，容器 `devops-platform-jenkins` |
| Java | Temurin OpenJDK `21.0.11` LTS |
| Docker Client/Server | `29.7.2` |
| Git | `2.47.3` |
| kubectl | `v1.36.1` |
| Helm | `v4.2.0` |
| ShellCheck | `0.10.0` |
| Jenkins 地址 | `http://localhost:8090`，只绑定 `127.0.0.1` |
| 应用地址 | `http://localhost:8080` |
| Jenkins Home | Docker named volume `devops-platform-jenkins-home` |

Jenkins 管理员用户名是 `zing`；Docker Hub namespace 是 `zingzin`。密码、PAT、token 和 kubeconfig 内容不记录在本文件中。

## 3. 九阶段流水线

仓库根目录 `Jenkinsfile` 顺序执行：

1. `Checkout`：检出 GitHub `main` 并生成 `git-<sha12>` 标签。
2. `Unit Test`：运行 14 项 pytest 并发布 JUnit XML。
3. `Quality Check`：执行 Git、Bash、ShellCheck、Helm 和秘密形状检查。
4. `Build Images`：构建 frontend/backend 镜像并写入 OCI revision。
5. `Image Verification`：检查非 root、Nginx、Gunicorn/Flask 和生产依赖。
6. `Push Images`：使用 Jenkins Credential `dockerhub-ci` 推送 Docker Hub。
7. `Deploy`：使用 `k3d-deployer-kubeconfig` 执行受保护的 Helm upgrade。
8. `Rollout Verification`：验证 Deployment、StatefulSet、rollout 状态和 Deployment 模板镜像。
9. `Smoke Test`：从真实 Ingress 检查健康、就绪、页面和 `/api/items`。

Pipeline 总超时 30 分钟、禁止并发部署同一 release、保留最近 20 次构建，并配置 `pollSCM('H/5 * * * *')`。

## 4. 手工构建证据

2026-08-19，Jenkins Build `#5` 全阶段成功：

- Git 提交：`43e572a724e4...`
- 镜像标签：`git-43e572a724e4`
- frontend：`zingzin/devops-web-platform-frontend:git-43e572a724e4`
- backend：`zingzin/devops-web-platform-backend:git-43e572a724e4`
- pytest：14 项通过
- Helm release：`devops-platform`
- Helm revision：`14`，状态 `deployed`
- frontend Deployment：`1/1 Ready`
- backend Deployment：`1/1 Ready`
- MySQL StatefulSet：`1/1 Ready`

## 5. 独立实时验收

`make phase4-verify` 已实际执行并通过。脚本验证：

- Jenkins 健康、CLI 可用、Home 使用预期 named volume；
- 两个 Deployment 使用同一个 `git-<sha12>` 标签；
- 两个公共 Docker Hub manifest 可读取；
- Helm 状态、rollout、StatefulSet 和 Pod 实际镜像一致；
- `/healthz`、`/readyz`、首页 Phase 4 标记和 `/api/items` 正常；
- 从 API 按唯一标题发现持久化记录 `TASK-017`（numeric ID `17`）；
- 只重启 Jenkins 容器后，Pipeline Job、构建历史、管理员用户、两个 Credential ID 和 `TASK-017` 仍存在。

验收输出摘要：

```text
[phase4-verify] Acceptance passed: image tag git-43e572a724e4, Helm revision 14, persistence marker 17
```

脚本通过 Jenkins Home 中的 Job 配置文件验证重启持久化，不要求把 Jenkins 管理员密码或 API Token 交给自动化。

## 6. 凭据与权限边界

Jenkins 只保存：

- `dockerhub-ci`：Docker Hub 用户名与有限期 Read & Write PAT；
- `k3d-deployer-kubeconfig`：`devops-platform` namespace 专用 ServiceAccount kubeconfig。

当前两个凭据位于本地单控制器的 `System / Global` store，而不是 Folder store；同一控制器上的其他 Job 理论上也可引用。这是为了控制初学项目复杂度而接受并公开的限制，生产或共享 Jenkins 应使用 Folder 级凭据或独立 Controller。

ServiceAccount 不具备 Node 或集群级 Namespace 读取权限。Helm release 状态也存储为同 namespace Secret，因此该身份在 namespace 内仍需要 Secret 权限；这是本地教学环境的明确限制，不描述为生产级强隔离。

Jenkins 挂载 Docker Socket，等价于较高的宿主 Docker 权限，因此只构建可信公开仓库的 `main`，不执行未知 Pull Request Jenkinsfile，也不通过公网隧道暴露 Jenkins。

## 7. Poll SCM 自动触发证据

2026-08-21，推送提交 `04888e5348f3...` 后，Jenkins 自动创建 Build `#6`，触发原因记录为 `SCMTriggerCause`，证明 `pollSCM('H/5 * * * *')` 能发现 GitHub `main` 新提交，无需手动点击 `Build Now`。

该次构建在 Deploy 阶段遇到“终止中旧 Pod 被纳入镜像检查”的竞态误报。Helm Revision `15` 和 Kubernetes 工作负载实际已经升级成功；修复与复现证据记录在 `docs/troubleshooting/phase-4-jenkins-cicd.md`。因此自动触发能力已验收，但仍需用修复提交获得一次完整绿色的自动流水线。

## 8. 尚待完成的验收

- 推送 rollout 竞态修复并获得一次完整绿色的 Poll SCM 自动流水线；
- 完成独立技术审查并处理审查意见；
- 最终更新 README、架构和部署文档后运行干净工作树发布门禁。

在这些项目完成前，本文件不把 Phase 4 标记为最终发布完成。
