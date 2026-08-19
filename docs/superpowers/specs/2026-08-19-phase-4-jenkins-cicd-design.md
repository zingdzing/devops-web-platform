# Phase 4 Jenkins CI/CD 流水线设计

## 1. 阶段目标

Phase 4 在已经完成的 Phase 3 Kubernetes/Helm 运行平台上增加一条可审计、可失败、可恢复的 Jenkins CI/CD 流水线。代码进入 GitHub `main` 分支后，Jenkins 依次检出代码、运行测试与静态检查、构建并验证前后端镜像、推送 Docker Hub、通过 Helm 更新现有 k3d 集群，并从真实 NGINX Ingress 入口完成端到端冒烟测试。

本阶段不增加新的业务功能，也不重建 MySQL。重点是把 Phase 1～3 已经验证的手工交付步骤串成一条完整、可追踪的自动化发布链路。

完成后应能够从任意一次 Jenkins 构建追溯到对应 Git 提交、两个 Docker Hub 镜像标签、Helm Revision 和 Kubernetes 中实际运行的镜像；失败时必须在扩大影响前停止，并保留不含秘密的排错证据。

## 2. 与项目目标的匹配结论

- **简历价值明确**：覆盖 Jenkinsfile、Declarative Pipeline、pytest、ShellCheck、Docker 构建与镜像仓库、Git SHA 版本、Helm upgrade、Kubernetes rollout、健康检查和失败诊断。
- **规模适中**：使用一个本地 Jenkins Controller 和现有单节点 k3d；不加入 Kubernetes Agent、DinD、Kaniko、SonarQube、Nexus、Harbor、多环境或云平台。
- **链路完整**：不是只展示 Jenkins 页面，而是验证 `GitHub -> Jenkins -> Docker Hub -> Helm -> Kubernetes -> NGINX Ingress -> 应用 -> MySQL`。
- **适合学习**：采用顺序执行的九个清晰阶段，日志容易对应到工具和故障位置；先完成项目，再按阶段学习。
- **描述诚实**：这是本地实验环境中的 CI/CD 实践，不声称生产级权限隔离、高可用、零停机保证或无人值守自动回滚。

## 3. 方案选择

### 3.1 Jenkins 运行方式

采用固定版本的 Jenkins LTS JDK 21 官方镜像作为基础，在自定义镜像中安装本项目需要的 CLI 和最少插件。Jenkins 作为 Docker 容器运行：

```text
Windows / Docker Desktop
  |
  +-- Jenkins container :8090
  |     +-- /var/jenkins_home -> named volume
  |     +-- /var/run/docker.sock -> Docker Engine
  |     +-- Git, Python, Docker CLI, kubectl, Helm, curl, jq, make, ShellCheck
  |
  +-- existing k3d / K3s cluster :8080
```

Jenkins Home 使用命名卷，容器重建不丢失用户、任务、插件、凭据和构建历史。Jenkins 只绑定本机 `127.0.0.1:8090`，不映射 Agent 端口，不对公网开放。

Docker Socket 挂载使 Jenkins 能复用 Docker Desktop 构建镜像，但等价于很高的宿主 Docker 权限。本方案仅允许可信 `main` 分支 Jenkinsfile，不执行陌生 Pull Request，不把它描述成生产安全模型。

不采用：

- Docker-in-Docker：引入额外守护进程、特权容器和缓存管理。
- Kubernetes Jenkins Agent：增加 Pod Template、Agent 镜像和动态调度概念。
- Kaniko/BuildKit 独立服务：当前本地项目没有摆脱 Docker Socket 的必要收益。
- Jenkins Configuration as Code：首版保留一次手动初始化和凭据录入，帮助理解 Jenkins UI；可作为后续增强。

### 3.2 镜像仓库与版本

使用两个公开 Docker Hub 仓库：

```text
zingdzing/devops-web-platform-frontend
zingdzing/devops-web-platform-backend
```

每次构建使用同一个提交派生的标签：

```text
git-<前12位Git SHA>
```

例如：

```text
zingdzing/devops-web-platform-frontend:git-12ab34cd56ef
zingdzing/devops-web-platform-backend:git-12ab34cd56ef
```

不使用 `latest`。Docker Hub Tag 在技术上仍可被覆盖，因此文档称其为“提交可追踪标签”，不虚称仓库已经强制不可变。镜像额外写入 OCI revision/source/build-number 标签，验收时检查运行中的 Pod 与当前 Git SHA 一致。

### 3.3 GitHub 触发方式

仓库公开，Jenkins 通过 HTTPS 匿名检出，不保存 GitHub密码、PAT 或个人 SSH 私钥。初次联调由用户点击 `Build Now`；全链路稳定后启用 `pollSCM('H/5 * * * *')` 检查 `main` 分支新提交。

不使用公网 Webhook 隧道，避免把本地 Jenkins 暴露到互联网。Phase 4 使用单 Pipeline Job 且固定构建 `main`，不引入 Multibranch Pipeline。

## 4. 总体交付流

```text
GitHub main
  |
  v
Jenkins Checkout
  |
  v
pytest -> ShellCheck/Helm checks
  |
  v
Build + verify frontend/backend images
  |
  v
Docker Hub (git-<sha>)
  |
  v
Helm upgrade existing release
  |
  v
Kubernetes rollout verification
  |
  v
host.docker.internal:8080 -> F5 NGINX Ingress -> app -> MySQL
```

质量和配置检查先执行，只有通过后才进入构建、发布和部署。九个阶段顺序执行，首版不并行，以降低本机资源竞争并让初学者能够从 Stage View 直接定位失败。

## 5. Jenkins Pipeline 设计

使用仓库根目录 `Jenkinsfile` 的 Declarative Pipeline。全局设置包括：

- 单 Jenkins Controller 执行；
- 总超时 30 分钟；
- `disableConcurrentBuilds()`，避免两个构建同时更新同一 Helm Release；
- 保留最近 20 次构建；
- 日志时间戳；
- 最终启用约每 5 分钟一次的 Poll SCM；
- 非敏感常量保存在 Pipeline environment；凭据只在所需 Stage 内绑定；
- `post` 中先归档测试/诊断证据，再做非破坏性清理。

### 5.1 Checkout

输入：公开 GitHub 仓库、Job 固定的 `main` 分支和待构建提交。

动作：`checkout scm`，确认分支来源，获取完整 SHA 和前 12 位，生成 `IMAGE_TAG=git-<sha12>`，记录构建编号。

输出：工作区、`GIT_COMMIT_FULL`、`GIT_COMMIT_SHORT`、`IMAGE_TAG` 和构建元数据。

失败：检出失败、提交无法解析、来源不是 `main`。失败后不运行任何测试或发布动作。

作用：建立 Git、Jenkins、镜像和部署之间的追踪起点。

### 5.2 Unit Test

输入：Flask 代码、`requirements-dev.txt` 和现有 14 项 pytest。

动作：创建 `.venv-ci`、安装测试依赖、运行 `pytest --junitxml=reports/pytest.xml`，由 Jenkins JUnit Publisher 读取结果。

输出：测试通过数、JUnit XML 和 Jenkins 测试趋势。

失败：依赖安装失败、任一测试失败或报告缺失。失败后不构建镜像。

作用：在生成制品前拦截业务回归。

### 5.3 Quality Check

输入：Git 跟踪文件、Shell 脚本、Dockerfile 和 Helm Chart。

动作：运行 `git diff --check`、`bash -n`、ShellCheck、`helm lint`、`helm template`、Phase 3 manifest 合同检查，以及秘密形状/浮动标签检查。

输出：代码、脚本和部署配置检查结果。

失败：Shell/Helm错误、Chart无法渲染、跟踪了秘密形状文件、出现已知Token/私钥签名或部署镜像使用 `latest`。

作用：把运维脚本和基础设施声明作为代码检查。

### 5.4 Build Images

输入：两个 Dockerfile、公开仓库名、Git SHA和Jenkins构建编号。

动作：构建前端和后端镜像，添加 OCI source/revision 和 Jenkins build-number 标签，输出镜像 ID/Tag 记录。

输出：两个本地 `git-<sha12>` 镜像和 `reports/images.txt`。

失败：Docker Engine不可用、Dockerfile失败、依赖下载失败或标签合同不满足。

作用：产生可交付、可追踪的容器制品。

### 5.5 Image Verification

输入：刚构建的两个镜像。

动作：检查镜像 revision；验证前后端运行用户不是 root；运行前端 `nginx -t`；检查 Gunicorn 能加载 Flask 应用；确认后端生产镜像不包含 pytest。

输出：镜像合同验证结果。

失败：镜像缺失、revision不匹配、root运行、Nginx配置错误、应用无法加载或生产镜像包含测试工具。

作用：区分“Docker build命令成功”和“镜像符合运行要求”。

### 5.6 Push Images

输入：通过验证的镜像和 Jenkins Credential `dockerhub-ci`。

动作：在关闭命令回显的凭据绑定块中使用 `docker login --password-stdin`，推送两个标签，最后 `docker logout`。

输出：Docker Hub中两个同SHA镜像地址。

失败：认证失败、权限不足、仓库不存在、网络失败或任一镜像推送失败。失败后不部署。

作用：把本地制品交付到集群可拉取的远程仓库。

### 5.7 Deploy

输入：两个镜像地址/标签、Helm Chart和 Secret File Credential `k3d-deployer-kubeconfig`。

动作：验证kubeconfig只指向目标k3d、命名空间/外部数据库Secret/PVC存在，然后执行 `helm upgrade --install`，仅通过 `--set-string`覆盖前后端 repository/tag，使用等待和Helm事务失败回滚。

输出：新 Helm Revision 和期望镜像。

失败：认证/授权失败、集群身份错误、数据库保护对象缺失、Helm失败或等待超时。

作用：把远程镜像转换为Kubernetes声明式更新，不从本地 `.env` 创建或修改数据库身份。

### 5.8 Rollout Verification

输入：目标Deployment、StatefulSet和期望SHA标签。

动作：`kubectl rollout status`检查frontend/backend，确认MySQL Ready，读取Pod实际镜像并与期望完全匹配，记录Pod状态。

输出：Ready状态和实际镜像证据。

失败：CrashLoopBackOff、ImagePullBackOff、超时、MySQL不Ready或实际镜像不一致。

作用：确认Helm命令成功后，工作负载确实运行了本次制品。

### 5.9 Smoke Test

输入：Jenkins容器到宿主入口 `http://host.docker.internal:8080`。

动作：带 `Host: localhost` 请求 `/healthz`、`/readyz`、`/` 和 `/api/items`；在有限轮询窗口内要求HTTP 200、Phase 4页面标志和合法JSON。只读GET，不创建或删除业务数据。

输出：真实Ingress链路的HTTP/内容验收结果。

失败：入口不可达、状态码错误、页面标志缺失、API不是合法JSON或超时。

作用：从用户入口证明Ingress、前端、后端和MySQL共同可用。

## 6. 凭据边界

### 6.1 Jenkins持有的凭据

| Credential ID | Jenkins类型 | 最小用途 |
|---|---|---|
| `dockerhub-ci` | Username with password | 用户名为Docker ID，password字段保存Read & Write PAT |
| `k3d-deployer-kubeconfig` | Secret file | 访问现有本地k3d的专用ServiceAccount kubeconfig |

凭据定义在项目Folder可用的最低范围。Pipeline只使用Credential ID，不包含真实值；Secret file绑定在工作区外的临时目录，任务结束后删除。

### 6.2 Jenkins不持有的内容

- GitHub密码、2FA、恢复码和个人SSH私钥；
- Docker Hub账号密码、2FA和恢复码；
- Windows、Ubuntu或SSH私钥口令；
- 根目录 `.env`；
- MySQL用户、应用密码或root密码；
- 渲染后的Secret YAML。

MySQL运行凭据继续只存在于被忽略的 `.env` 和Kubernetes外部Secret。Jenkins可检查Secret对象存在，但不输出其数据，也不执行创建、更新或删除数据库Secret的命令。

### 6.3 Kubernetes部署身份与限制

创建 `jenkins-deployer` ServiceAccount和命名空间级Role/RoleBinding，不使用个人管理员kubeconfig，不授予ClusterRole。因为Jenkins在集群外且本地项目不增加自动Token代理，使用可吊销的长期ServiceAccount Token；这是明确记录的本地实验折中，不是生产建议。

Helm默认把Release状态保存为同命名空间Secret。标准RBAC不能按标签表达“只允许Helm Secret、绝对禁止数据库Secret”，因此当前边界包含两个层次：

1. 权限只覆盖 `devops-platform` 命名空间，不覆盖集群和其他命名空间；
2. 受信任Jenkinsfile在行为上只修改镜像字段，不读取数据库Secret内容。

完全强隔离需要拆分Release/Namespace或引入专门Secret方案，超出Phase 4范围。文档必须公开这一限制。

## 7. 失败处理与恢复

### 7.1 Fail-fast边界

- Checkout/测试/质量失败：不构建；
- 构建/镜像验证失败：不推送；
- 推送失败：不部署；
- Helm/Rollout失败：停止，保存集群现场；
- Smoke失败：构建标记失败并保留当前状态，人工区分应用故障与Windows 8080/网络入口故障；
- 诊断和清理失败只记录警告，不覆盖原始失败原因。

核心步骤不得使用 `|| true` 隐藏失败。只有 `post` 诊断、logout和删除本次本地镜像等清理允许非致命失败。

### 7.2 重试策略

- Git检出和Python依赖下载最多重试2次；
- Docker Hub push最多重试3次；
- Ingress健康检查在约60秒条件轮询内重试；
- Kubernetes rollout/Helm等待有明确5分钟上限；
- 测试、语法、认证、Forbidden、错误集群和秘密缺失不自动重试。

### 7.3 回滚边界

保留Helm操作本身的事务失败回滚，使未成功的upgrade尽量返回上一Revision。若Helm已成功而最终Smoke失败，Jenkins不自动追加 `helm rollback`：本地8080端口冲突或Jenkins到宿主网络问题可能造成误判。流水线收集证据后，由Runbook指导人工选择修复入口或回滚到明确Revision。

### 7.4 诊断与数据保护

失败时记录Git SHA、构建号、失败Stage、镜像标签、Helm Revision、Pod/Deployment/Ingress/PVC状态、近期Events和前后端日志；禁止输出Secret YAML、`.env`、凭据环境变量全集或Token。

任何Pipeline路径都不得自动执行：

```text
kubectl delete pvc
kubectl delete namespace
helm uninstall
docker volume prune
docker system prune -a
```

MySQL PVC、数据库Secret、已有远程镜像和Jenkins历史始终保留。

## 8. 验收标准

### 8.1 Jenkins与工具

- `http://localhost:8090`可登录，Jenkins只绑定本机；
- Jenkins Home命名卷存在，容器重建后账号、Job、凭据和历史仍在；
- 容器内Git、Bash、Python/venv、Docker CLI、kubectl、Helm、curl、jq、make和ShellCheck可用；
- Docker Engine和k3d API可从Jenkins容器访问。

### 8.2 全流水线

- Stage View清楚显示九个阶段；
- 现有14项pytest通过并生成JUnit报告；
- Shell/Helm/秘密检查通过；
- 两个镜像构建和镜像合同验证通过；
- Docker Hub出现同一Git SHA的两个公开镜像；
- Helm Revision增加，frontend/backend实际运行该SHA标签；
- frontend、backend和MySQL均Ready，无CrashLoopBackOff/ImagePullBackOff；
- `/healthz`、`/readyz`、首页和`/api/items`从真实Ingress入口通过；
- Pipeline前创建的任务在部署和MySQL Pod重建后仍存在。

### 8.3 触发、安全和恢复

- 第一次 `Build Now` 完整成功；
- 启用Poll SCM后，一个新的正常main提交能自动触发；
- Git和日志中没有密码、PAT、Token、私钥、kubeconfig或恢复码；
- 凭据错误、权限错误和Smoke失败会停在设计的边界；
- Jenkins容器重启和应用重复部署均不丢数据；
- Runbook提供明确的诊断、凭据轮换和手动Helm回滚步骤。

## 9. 文件边界

预计新增：

```text
Jenkinsfile
deploy/jenkins/
  Dockerfile
  compose.yaml
  entrypoint.sh
  plugins.txt
deploy/kubernetes/jenkins-rbac.yaml
scripts/ci/
  common.sh
  unit-test.sh
  quality-check.sh
  build-images.sh
  verify-images.sh
  deploy.sh
  smoke-test.sh
  collect-diagnostics.sh
scripts/create-phase4-kubeconfig.sh
scripts/check-phase4-contract.sh
scripts/verify-phase4.sh
docs/implementation/phase-4-jenkins-cicd.md
docs/troubleshooting/phase-4-jenkins-cicd.md
docs/runbooks/phase-4-jenkins-operations.md
docs/reviews/phase-4-independent-review.md
```

预计修改：

```text
.gitignore
Makefile
README.md
app/frontend/src/index.html
deploy/README.md
docs/architecture.md
```

CI脚本按职责拆分，Jenkinsfile只负责Stage编排和凭据生命周期，不堆积所有Shell实现。Phase 3的本地构建/import/Secret管理脚本继续保留，Jenkins部署不得直接调用 `deploy-phase3.sh`。

## 10. 不在Phase 4范围内

- Jenkins Kubernetes Agents和多节点Controller/Agent架构；
- Webhook公网暴露、反向代理TLS和企业SSO；
- SonarQube、Nexus、Harbor、Trivy强制门禁；
- 多环境、多分支、审批门、蓝绿或金丝雀发布；
- 自动数据库迁移和数据库密码轮换；
- 自动业务回滚；
- Prometheus、Grafana和Alertmanager（Phase 5）；
- 失败发布与人工回滚专项演练（Phase 6深化）。

## 11. 简历与证据

验收后保留不含秘密的Jenkins Stage View、JUnit报告、Docker Hub SHA标签、Helm Revision、Ready Pods、Phase 4页面和数据持久化证据。README与简历只能使用实测数字，预期包括九个Pipeline阶段、14项测试、两个镜像和一条端到端自动部署链路。

建议简历描述（仅在验收通过后使用）：

> 设计并实现基于Jenkins的CI/CD流水线，集成pytest、ShellCheck、Docker、Docker Hub、Helm及Kubernetes，实现前后端镜像的Git SHA版本管理、自动构建发布、滚动部署、健康检查和端到端冒烟验证；通过Jenkins Credentials、Kubernetes Secret和PVC实现交付凭据边界与MySQL数据持久化。

不声称当前项目具备生产高可用、严格Secret零访问、企业级供应链安全或零停机保证。
