# Phase 4 Jenkins CI/CD 真实故障记录

本文件只记录实施过程中实际出现的问题。每项包含现象、安全证据、根因、修正和预防措施，不包含密码、PAT、token、kubeconfig 或 Secret 数据。

## 1. Checkout 阶段 Git TLS 连接中断

**现象**

首次 Jenkins Checkout 在匿名 HTTPS 拉取公开 GitHub 仓库时失败，日志包含 `GnuTLS recv error (-9)` 和远端提前关闭连接。

**根因**

一次临时网络/TLS 传输中断，不是仓库权限或 Git 凭据错误。

**修正**

`Checkout` 对 `checkout scm` 与 `git fetch origin main` 使用最多三次有界重试，同时继续验证工作区 HEAD 等于 `origin/main`。

**预防**

只重试幂等的代码检出，不对部署阶段进行无条件重复；保留最终失败日志以区分网络波动与权限问题。

## 2. ShellCheck 信息级规则阻断 Quality Check

**现象**

流水线运行到 ShellCheck 时因 `SC2317` 信息级提示停止，而该提示受 ShellCheck 版本影响，并非脚本运行错误。

**根因**

质量门禁把信息级版本差异当成了必须阻断发布的错误。

**修正**

CI 使用 `shellcheck --severity=warning`，仍然阻断 warning/error，同时不因版本相关 info 提示失败。合同检查固定这一策略。

**预防**

明确质量门禁的严重级别，而不是简单把任意工具输出都当作发布失败。

## 3. Deploy 阶段越过 namespace 权限边界

**现象**

Build `#3` 的前六阶段成功，Deploy 立即失败：

```text
User "system:serviceaccount:devops-platform:jenkins-deployer"
cannot get resource "namespaces"
```

**根因**

部署脚本先执行集群级 `get namespace`，但 Jenkins ServiceAccount 按设计只有 `devops-platform` namespace 内权限。脚本与最小权限模型互相矛盾。

**修正**

没有扩大 RBAC。脚本改为从 kubeconfig 本地读取并验证目标 context/namespace，再通过 Helm release、Secret 对象存在性和 PVC 状态证明 namespace 内访问可用。

**预防**

合同检查禁止 CI 部署脚本读取集群级 Namespace 对象，并要求本地验证 kubeconfig namespace。受限账号仍不能读取 Node 或 Namespace。

## 4. 实时验收访问 127.0.0.1 得到 NGINX 404

**现象**

首次 `make phase4-verify` 到达 Ingress 检查后收到 HTTP 404；Pod、Service 和 Ingress 均为 Ready。

**根因**

Ingress 规则的 host 是 `localhost`。验收脚本使用 `http://127.0.0.1:8080`，请求到达 NGINX，但 `Host: 127.0.0.1` 不匹配规则，因此命中默认 404。

**修正**

验收入口改为 `http://localhost:8080`。逐个检查 `/healthz`、`/readyz`、`/` 和 `/api/items` 后均返回 200。

**预防**

合同检查固定 `localhost` Ingress Host；排查入口问题时同时检查端口、Host、路径和 Server 响应，而不是只看 Pod 状态。

## 5. Jenkins 与 Docker Hub 用户名混淆

**现象**

Edge 在 Jenkins 登录页自动填入 Docker Hub 用户名 `zingzin`，登录失败。

**根因**

两个本地站点的用户名相近：Jenkins 管理员是 `zing`，Docker Hub namespace 是 `zingzin`。浏览器自动填充选择了错误记录。

**修正**

只读检查 Jenkins Home 用户配置确认实际 ID 为 `zing`，使用正确用户名登录；没有删除 Jenkins Home，也没有执行密码重置。

**预防**

密码管理器中使用清晰条目名称，例如“Local Jenkins 8090”和“Docker Hub”，并保持密码互不相同。

## 6. Poll SCM 自动构建在 rollout 后误报旧 Pod 镜像

**现象**

GitHub `main` 推送 `04888e5348f3...` 后，Jenkins 通过 Poll SCM 自动触发 Build `#6`。Checkout、测试、质量、镜像构建、镜像检查和推送均成功，Helm Revision `15` 也完成升级，但 Deploy 阶段报告 backend 仍为上一个标签 `git-43e572a724e4`。

**安全证据**

失败后的 Helm values、Deployment 模板、当前 Ready Pod 和 ReplicaSet 均已使用 `git-04888e5348f3`。Kubernetes 事件显示新版 backend Ready 后，旧 backend Pod 才进入终止流程。

**根因**

`kubectl rollout status` 成功后，部署脚本继续枚举该组件的全部 Pod，并要求每个 Pod 都使用新镜像。滚动更新交接瞬间，旧 Pod 可能仍短暂出现在 API 列表中，因此脚本把正常的终止中 Pod 当成当前工作负载，产生竞态误报。

**修正**

保留 `kubectl rollout status` 作为新版可用性门禁；随后核对 Deployment Pod template 的声明镜像是否等于本次不可变标签。修复后以受限 `jenkins-deployer` kubeconfig 执行 `--verify-only`，前后端 rollout 与镜像核验均通过。

**预防**

Phase 4 合同检查要求部署核验读取 Deployment template，并禁止在 rollout 成功后通过枚举过渡期 Pod 判定版本。Pod 健康仍由 rollout、readiness/startup probe 和 Smoke Test 共同证明。

## 7. 成功构建重复归档旧 Kubernetes 诊断

**现象**

Build `#8` 本身由 Poll SCM 自动触发且结果为 `SUCCESS`，但其归档的 `kubernetes-diagnostics.txt` 仍写着 Build `#6`、提交 `04888e5348f3...` 和 Helm Revision `15`。

**根因**

Kubernetes 诊断只在失败时生成；Jenkins 重用同一个 workspace，而 Checkout 前没有清理目录。Build `#6` 留下的诊断文件因此跨越 Build `#7/#8` 存在，并被 `archiveArtifacts reports/**/*` 再次归档。部署、测试和镜像并未失败，但证据文件已经陈旧。

**修正**

在 Checkout 的第一次操作中调用 Jenkins `deleteDir()`，随后再检出 Git 仓库。每次 Pipeline 都从空 workspace 开始，测试报告、镜像清单和失败诊断只能来自当前构建。

**预防**

Phase 4 合同检查要求 Checkout 包含 `deleteDir()`。验收构建时不仅看 Stage 颜色，还抽查归档文件中的 `build_number`、`git_commit` 和当前 Build 是否一致。
