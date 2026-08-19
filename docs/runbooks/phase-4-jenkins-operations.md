# Phase 4 Jenkins CI/CD Operations Runbook

本手册面向本地学习环境。所有命令都假定刚打开 Ubuntu 终端；先进入 Phase 4 工作树：

```bash
cd ~/projects/devops-web-platform-phase4
```

不要把 Jenkins 密码、Docker Hub PAT、恢复码、ServiceAccount token、kubeconfig 或 `.env` 发给他人，也不要提交到 Git。

## 1. Jenkins 日常启动、检查与停止

启动并等待健康：

```bash
cd ~/projects/devops-web-platform-phase4
make phase4-jenkins-up
```

浏览器访问 `http://localhost:8090`。查看日志：

```bash
cd ~/projects/devops-web-platform-phase4
make phase4-jenkins-logs
```

按 `Ctrl+C` 只退出日志跟随，不会停止 Jenkins。安全停止：

```bash
cd ~/projects/devops-web-platform-phase4
make phase4-jenkins-stop
```

停止不会删除名为 `devops-platform-jenkins-home` 的 Jenkins Home 卷。不要使用 `docker compose down --volumes`，也不要手工删除该卷，否则 Job、用户和凭据会丢失。

## 2. 第一次解锁与管理员密码

只在自己的终端读取一次性解锁值：

```bash
cd ~/projects/devops-web-platform-phase4
docker exec devops-platform-jenkins \
  cat /var/jenkins_home/secrets/initialAdminPassword
```

它不是以后登录用的管理员密码。完成向导时创建独立、唯一的 Jenkins 管理员密码，并保存在个人密码管理器中。不要与 GitHub、Docker Hub、Ubuntu、SSH 私钥口令或数据库密码相同。

如果忘记 Jenkins 管理员密码，先检查密码管理器和仍然有效的管理员会话。一次性解锁值在初始化后不能当作普通登录密码。涉及临时关闭安全或直接修改 Jenkins Home 的恢复操作风险较高，必须先备份 Jenkins Home，并按当时 Jenkins 官方恢复流程处理；不要通过删除 Jenkins Home 卷“重装”来碰运气。

## 3. Jenkins 凭据及轮换

Jenkins 只保存两个项目凭据：

| ID | 类型 | 内容 | 用途 |
|---|---|---|---|
| `dockerhub-ci` | Username with password | 用户名 `zingzin`，Password 填 Docker Hub PAT | 只在 Push Images 阶段登录 Docker Hub |
| `k3d-deployer-kubeconfig` | Secret file | 临时生成的专用 kubeconfig 文件 | 只在部署、验证和失败诊断时访问目标 namespace |

不要在 Pipeline 全局 `environment` 中保存凭据，也不要在 Console Log 中打印它们。

### Docker Hub PAT 轮换

1. 在 Docker Hub 创建新的 Read & Write PAT，设置有限有效期。
2. 在 Jenkins 中编辑 ID 为 `dockerhub-ci` 的凭据，用新 PAT 替换 Password。
3. 运行一次 Pipeline，确认两个镜像均可推送。
4. 回到 Docker Hub 撤销旧 PAT。

PAT 不是 Docker Hub 登录密码，也不是 Jenkins 密码。忘记 PAT 时通常无法查看旧值；应创建新 PAT、更新 Jenkins，再撤销旧 PAT。

### Kubernetes ServiceAccount token 轮换

轮换会让旧 kubeconfig 立即失效，应安排在没有 Pipeline 运行时：

```bash
cd ~/projects/devops-web-platform-phase4
kubectl delete secret jenkins-deployer-token -n devops-platform
make phase4-kubeconfig
```

在 Jenkins 中用新 `/tmp/devops-platform-jenkins-kubeconfig` 替换 ID 为 `k3d-deployer-kubeconfig` 的 Secret file，验证 Pipeline 后，只删除这个临时文件：

```bash
rm -f -- /tmp/devops-platform-jenkins-kubeconfig
```

不要删除个人 kubeconfig（例如 `~/.kube/config`）。

## 4. 失败检查与手工回滚

先看 Jenkins 对应 Stage、JUnit 结果和归档的 `reports/`。查看当前资源：

```bash
cd ~/projects/devops-web-platform-phase4
kubectl get pods,svc,ingress,pvc -n devops-platform
helm history devops-platform -n devops-platform
```

Pipeline 中的 Helm 事务只在 Helm upgrade 本身失败时自动回滚。冒烟测试失败后不会再次自动回滚，避免掩盖已经成功部署但入口异常的真实状态。

确认目标历史 revision 后，才手工执行：

```bash
helm rollback devops-platform <revision> -n devops-platform --wait
```

把 `<revision>` 替换为 `helm history` 中确认过的数字。回滚前后都要检查 Pod、Ingress 和页面。不要执行 `helm uninstall`、删除 namespace、删除数据库 Secret 或删除 PVC；这些动作可能中断服务或丢失数据。

## 5. 安全边界与已知限制

- Jenkins 绑定 `127.0.0.1:8090`，不发布 Agent 端口 50000，也不通过公网隧道暴露。
- Jenkins 容器挂载 Docker Socket。获得 Jenkins 管理权限的人实际上可控制宿主 Docker，因此本方案只适合受信任的本地仓库 `main`，不运行未知 Pull Request 的 Jenkinsfile。
- `jenkins-deployer` 使用 namespace 级 Role，不能读取 Node 或管理集群级资源。
- Helm 默认把 Release 状态保存在同 namespace 的 Secret 中。标准 RBAC 无法只允许 Helm Release Secret、同时绝对禁止数据库 Secret，因此该身份在 `devops-platform` 内仍具有 Secret 权限；Jenkinsfile 的行为约束是不读取或修改数据库 Secret 内容。
- 数据库 Secret 和 PVC 由 Phase 3 保留。Pipeline 只覆盖前后端镜像 repository/tag，不从根目录 `.env` 创建数据库身份。
- 本地 ServiceAccount token 是长期令牌，便于教学演示；真实生产环境应使用短期身份、外部凭据系统或云工作负载身份。

## 6. 常用健康检查

```bash
cd ~/projects/devops-web-platform-phase4
docker inspect --format '{{.State.Health.Status}}' devops-platform-jenkins
curl --fail http://127.0.0.1:8090/login >/dev/null
make phase4-contract
```

预期 Jenkins 为 `healthy`，登录页可访问，Phase 4 contract 通过。
