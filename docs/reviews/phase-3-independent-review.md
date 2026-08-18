# Phase 3 独立技术审查记录

## 审查范围与方式

2026-08-18，在 Phase 3 实现、跨阶段回归和文档完成后，由独立子代理对 `main...phase3-kubernetes-helm` 执行只读审查。审查者没有修改文件，重点检查 Kubernetes/Helm 生命周期、安全边界、故障清理、初学者项目规模、简历表述和测试缺口。

最终结论：所有 P1 已解决，没有 P0/P1 阻塞项；最后一个 P2 也在合并前处理。项目仍保留单节点、单副本和本地存储等已明确记录的限制。

## 发现与处置

### P1：外部 Secret 变化可能留下潜伏认证故障——已解决

**证据：** 原 `scripts/deploy-phase3.sh` 在 Helm upgrade 前直接更新 Secret，但 Pod 模板没有 Secret checksum；已有 PVC 中的 MySQL 账号不会因环境变量变化而轮换。旧 backend Pod 仍持有旧密码，部署可暂时显示成功，Pod 重建后才失败。Helm 回滚也不会回滚外部 Secret。

**处置：** `scripts/deploy-phase3.sh:30-67` 在已有 MySQL PVC 时，先比较持久化数据库身份（DB_NAME、DB_USER、DB_PASSWORD、MYSQL_ROOT_PASSWORD），不一致时在构建镜像、更新 Secret 和 Helm upgrade 之前拒绝部署。当前范围明确不实现在线凭据轮换。

**验证：** `scripts/verify-phase3.sh:278-300` 使用 mode 600 的临时环境文件改变密码，要求部署失败、错误信息解释 PVC 约束，并确认现有 Secret 密码未被修改。

### P2：快速启动没有保证 `.env` 为 mode 600——已解决

**证据：** 文档使用 `cp .env.example .env`，通常得到 644；原部署脚本只保护临时 Secret 文件，没有检查 `.env`。

**处置：** Phase 3 快速启动统一改为 `install -m 600 .env.example .env`。`scripts/deploy-phase3.sh:70-76` 和 `scripts/verify-phase3.sh:149-155` 都执行权限门禁并给出 `chmod 600` 修复提示。

**验证：** `scripts/verify-phase3.sh:282-289` 把临时环境文件设为 644，确认部署在任何镜像构建或 Secret 更新前拒绝。

### P2：停止后的恢复说明漏掉集群启动——已解决

**证据：** `make phase3-stop` 停止整个 k3d cluster；原实施文档只让用户重新运行 `make phase3-deploy`，但部署脚本要求节点已经 Ready。

**处置：** `docs/implementation/phase-3-kubernetes.md` 改为先运行 `make phase3-cluster-create`，再运行 `make phase3-deploy`，与 Runbook 和实际回归步骤一致。

### P3：固定 backend Service 降低 Chart 多实例复用性——接受限制并记录

**证据：** `deploy/helm/devops-web-platform/templates/backend-service.yaml` 固定名称为 `backend`，因为 Phase 2 前端镜像中的 Nginx upstream 使用该 DNS 名称。

**处置：** 不为本阶段加入运行时 Nginx 模板。`deploy/README.md` 和实施文档明确“一 namespace 一个 release”，不把 Chart 描述成通用多实例 Chart。项目专用 namespace 下该约束不影响当前部署。

### P3：文档固定“最终 Helm revision 5”会自然过期——已解决

**处置：** 实施记录改为“重复 upgrade 后 release 状态为 deployed”，保留日期和 Pod UID 证据，不再把动态 revision 当长期结论。

### P1：凭据门禁最初依赖 Helm ConfigMap，造成恢复循环——已解决

**证据：** 第一版修复从 Helm ConfigMap 读取 DB_NAME。`helm uninstall` 或失败回滚可能删除 ConfigMap但保留 PVC 和外部 Secret，下一次部署会在重新安装 Helm 之前失败。

**处置：** `scripts/deploy-phase3.sh:47-60,103-124` 把 DB_NAME 一并存入外部 Secret。旧 Secret 没有该 key 时，只在现有 ConfigMap 可用的情况下完成一次兼容迁移；以后身份比较只依赖随 PVC 一起保留的外部 Secret。

**验证：** `scripts/verify-phase3.sh:266-276` 先确认 Secret 保存 DB_NAME，实际删除 Helm ConfigMap，再调用标准部署脚本，要求 ConfigMap 被 Helm upgrade 恢复。该验收已实测通过。

### P2：ConfigMap 故障注入失败时缺少清理——已解决

**证据：** 验收删除 ConfigMap 后执行完整部署；如果构建、导入或 Helm upgrade 中途失败，原 cleanup 不会恢复 ConfigMap。

**处置：** `scripts/verify-phase3.sh:115-126,270-277` 使用 `configmap_deleted` 标志。只有验收自己删除且标准部署尚未恢复时，EXIT cleanup 才用 Helm 单独渲染并 apply ConfigMap；成功恢复后立即清除标志。

## 独立审查确认的优点

- 范围保持为单节点、单副本、无 TLS/HPA/云平台，适合初学者完成和讲解。
- README 明确区分 Pod 自愈与零停机高可用，简历表述诚实。
- Traefik、F5 NGINX Ingress Controller 和应用 Ingress 的职责边界清楚。
- frontend/backend 使用非 root、安全上下文、资源 requests/limits 和三类 Probe。
- MySQL 使用 StatefulSet、headless Service、PVC 与 Retain 策略，数据丢失边界写入 Runbook。
- 自动验收覆盖 Ingress CRUD、Pod 替换、数据库降级恢复、PVC 数据保留、重复部署、ConfigMap 生命周期和凭据负向测试。

## 最终验证证据

- Phase 1：14 个 pytest 通过。
- Phase 2：真实三容器验收通过，Compose 命名卷仍存在。
- Phase 3：`make phase3-verify` 通过，backend/MySQL Pod UID 均发生替换，数据保留，删除的 ConfigMap 被标准部署恢复，错误凭据未修改 Secret。
- Bash 语法、ShellCheck、`helm lint`、清单门禁、`git diff --check` 和敏感特征扫描通过。
- 最终运行态：单节点 Ready，frontend/backend/MySQL 均 `1/1 Ready`，PVC `Bound`，Helm release `deployed`，`/readyz` 返回 ready。
