# Phase 6：失败发布、自动回滚与恢复验收设计

## 1. 文档状态

- 状态：已确认设计，待实施计划
- 日期：2026-08-28
- 分支：`phase6-failure-recovery`
- 基线：Phase 5 已完成，Jenkins、Kubernetes、Helm、MySQL 与监控链路可用
- 目标环境：本机 WSL2、Docker Desktop、k3d 非生产集群

## 2. 背景与目标

当前项目已经具备应用、容器化、Kubernetes 部署、Jenkins CI/CD、Prometheus 监控、Grafana Dashboard 与 Alertmanager 告警。Phase 6 补充一条完整的失败发布处置链路，回答以下问题：

1. 错误版本能否在进入稳定环境前被识别并阻断？
2. Helm 能否在升级失败后恢复到上一个成功版本？
3. 回滚后应用、数据库持久化数据和监控是否仍然正常？
4. Jenkins 能否归档足够的诊断证据供排障和简历展示？

本阶段采用参数化 Jenkins 故障演练。演练必须手动启用、默认关闭，并仅面向本机非生产环境。它不模拟生产级混沌工程，也不宣称生产级容灾能力。

## 3. 与岗位和简历目标的关系

该设计符合运维、DevOps 和初级运维开发岗位常见工作内容：

- 参数化流水线与人工审批；
- Kubernetes 发布失败识别；
- Helm 自动回滚；
- Pod、事件、镜像与 Helm 历史诊断；
- 服务、数据、PVC 与监控恢复验证；
- 失败证据和排障记录归档。

建议简历表述：

> 基于 Jenkins 参数化 Pipeline 设计非生产环境故障发布演练，通过不存在的镜像标签触发 Kubernetes 拉取失败，验证 Helm 自动回滚、Jenkins 失败诊断归档、应用可用性恢复及 MySQL PVC 数据持久化。

不应表述为生产级灾难恢复、生产级混沌工程、金丝雀发布或多集群容灾。

## 4. 范围边界

### 4.1 本阶段包含

- Jenkins 布尔参数 `RUN_FAILURE_DRILL`，默认值为 `false`；
- 手动启用演练，并由 Jenkins `input` 步骤二次确认；
- 使用明确不存在的后端镜像标签触发 `ErrImagePull` 或 `ImagePullBackOff`；
- 使用 Helm 升级失败回滚能力恢复到基线版本；
- 在失败前、失败时和恢复后采集诊断证据；
- 验证应用、MySQL、PVC、监控和持久化标记数据；
- 运行一次预期红色演练构建，再运行一次正常绿色构建；
- 更新实施记录、Runbook、排障记录、架构说明和技术复核。

### 4.2 明确排除

- 删除 Namespace、Secret、PVC 或持久卷；
- 修改或泄露数据库、Docker Hub、Jenkins、Grafana 等凭据；
- 主动破坏 MySQL 数据；
- 停止 Docker Desktop、WSL 或整个 k3d 集群作为演练手段；
- 构建并推送恶意或损坏镜像；
- 修改主分支制造故障；
- 引入 Argo Rollouts、Flagger、多集群、蓝绿发布或生产级混沌平台。

## 5. 总体流程

```text
健康基线
  -> 手动启动 Jenkins，并设置 RUN_FAILURE_DRILL=true
  -> Jenkins 二次人工审批
  -> 记录 Git、镜像、Helm、工作负载、PVC、数据和监控基线
  -> 使用不存在的后端镜像标签执行 Helm upgrade
  -> Kubernetes 出现镜像拉取失败，新 Pod 无法就绪
  -> Helm 判断升级失败并自动回滚
  -> Jenkins 采集故障与回滚诊断
  -> 验证应用、数据、PVC 和监控恢复
  -> 将演练构建标记为预期失败并归档证据
  -> RUN_FAILURE_DRILL=false 再执行一次正常构建
  -> 正常构建全绿，证明交付链路恢复
```

演练构建的红色结果表示错误发布被阻断；后续正常构建的绿色结果表示交付链路与运行环境均已恢复。

## 6. Jenkins Pipeline 设计

### 6.1 参数与触发边界

- 新增布尔参数：`RUN_FAILURE_DRILL=false`；
- SCM 轮询或普通构建始终使用默认值，不进入演练；
- 只有用户手动设置为 `true` 时才运行故障演练；
- 演练开始前使用 `input` 进行二次确认；
- 审批用户限制为当前 Jenkins 管理员 `zing`；
- 参数为 `false` 时，现有构建、测试、镜像推送、部署和冒烟测试逻辑保持不变。

### 6.2 阶段顺序

保留现有阶段：

1. Checkout
2. Unit Test
3. Quality Check
4. Build Images
5. Image Verification
6. Push Images
7. Deploy
8. Rollout Verification
9. Smoke Test

在正常冒烟测试之后增加条件阶段：

10. Failure Drill
11. Declarative Post Actions

`Failure Drill` 仅在 `params.RUN_FAILURE_DRILL == true` 时执行。这样先证明当前版本健康，再在受控条件下演练失败和恢复。

### 6.3 构建结果语义

- 正常构建：全部正常阶段通过，演练阶段跳过，最终为绿色；
- 演练构建：故障注入成功、自动回滚成功、恢复验收成功后，脚本有意返回非零，最终为红色；
- 恢复失败：同样为红色，但报告必须明确标记为异常恢复失败，并打印人工恢复命令；
- 取消审批：不得修改集群，构建终止并保留审批取消记录。

必须通过报告字段区分 `EXPECTED_DRILL_FAILURE` 与 `RECOVERY_FAILURE`，避免只凭 Jenkins 颜色判断演练结论。

## 7. 故障注入设计

### 7.1 注入对象

只修改后端 Deployment 的目标镜像标签，格式为：

```text
zingzin/devops-web-platform-backend:failure-drill-<BUILD_NUMBER>-does-not-exist
```

该标签必须由脚本动态生成且明确不存在，不构建、不推送。

### 7.2 预期 Kubernetes 行为

- Deployment 创建新 ReplicaSet；
- 新 Pod 尝试拉取不存在的镜像；
- 新 Pod 进入 `ErrImagePull` 或 `ImagePullBackOff`；
- 由于 RollingUpdate，已有健康 Pod 在新 Pod 就绪前继续提供服务；
- Helm 等待资源就绪并在超时后判断升级失败；
- Helm 恢复到上一个成功 Release 状态。

### 7.3 选择该故障的原因

- 原因直观，初学者可以从镜像、Pod、Deployment 和 Helm 四层理解；
- 不需要修改应用或数据库代码；
- 不接触 Secret、PVC 和业务数据；
- 能稳定产生 Kubernetes 事件和可归档证据；
- 与真实工作中的错误镜像标签、镜像不存在或仓库路径错误相似。

## 8. Helm 回滚设计

故障发布使用与项目现有发布方式一致的 Helm upgrade，并启用失败回滚：

```text
helm upgrade --install ... --rollback-on-failure --wait=watcher --timeout=<有界时长>
```

具体 Release、Chart、Namespace 和 values 参数由实施阶段复用现有 CI 脚本，不在设计文档中重复硬编码。

### 8.1 预期路径

1. 记录演练前成功 Helm revision；
2. 提交不存在的后端镜像标签；
3. Helm upgrade 因工作负载未就绪而失败；
4. Helm 自动恢复到上一成功状态；
5. 对比恢复后的 revision、镜像和工作负载状态；
6. 完成业务、数据、PVC 和监控恢复验收。

### 8.2 异常恢复路径

若自动回滚没有恢复健康状态：

1. 立即停止后续故障操作；
2. 采集 Helm history、Pod、Deployment、ReplicaSet、事件和日志；
3. 尝试恢复到演练前记录的成功 revision；
4. 若自动恢复仍失败，输出明确的人工恢复命令和基线 revision；
5. 不得删除 Namespace、PVC、Secret 或数据库数据。

故障脚本必须使用退出捕获或等价机制，确保中途失败时仍执行诊断和恢复尝试。

## 9. 基线检查

进入故障注入前，必须记录并验证：

- Git commit SHA 和 Jenkins build number；
- Helm Release、当前成功 revision 和状态；
- 前端、后端和 MySQL 当前镜像；
- Deployment、StatefulSet 的 Ready 副本数；
- MySQL Pod 状态；
- PVC 名称和 UID；
- Phase 6 专用持久化标记任务的 ID、标题和内容；
- `/health`、`/ready`、任务 API 和前端页面；
- Prometheus 对应用的抓取目标为 UP；
- 监控命名空间关键工作负载处于健康状态。

任何基线检查失败时必须拒绝开始演练，避免把原有故障误认为演练结果。

## 10. 恢复验收标准

自动回滚后必须同时满足：

1. Helm Release 状态恢复为 `deployed`；
2. 后端镜像恢复为演练前基线镜像；
3. 前端、后端 Deployment 和 MySQL StatefulSet 均 Ready；
4. MySQL Pod 正常；
5. PVC 名称和 UID 与演练前一致；
6. Phase 6 持久化标记任务仍可读取，内容未改变；
7. `/health` 和 `/ready` 返回成功；
8. 任务 CRUD/API 与前端页面可用；
9. Prometheus 对应用的 Target 为 UP；
10. 监控工作负载未被演练修改，且无持续的严重活动告警；
11. Helm history 能说明失败升级和恢复结果；
12. 下一次 `RUN_FAILURE_DRILL=false` 的正常 Jenkins 构建全绿。

只有全部条件满足，才能认定 Phase 6 真实演练通过。

## 11. 诊断与归档

演练构建归档以下非敏感文件：

- `reports/phase6-baseline.txt`
- `reports/phase6-failure.txt`
- `reports/phase6-recovery.txt`
- `reports/kubernetes-diagnostics.txt`
- `reports/helm-history.txt`
- `reports/kubernetes-events.txt`
- `reports/images.txt`
- `reports/pytest.xml`

报告需包含时间、Build 编号、Git SHA、Helm revision、镜像、Pod 状态、事件摘要、恢复检查结果和最终结论。不得归档 kubeconfig、Token、密码、Secret 内容、Docker 配置或环境变量完整转储。

## 12. 代码与文档结构

计划修改或新增：

```text
Jenkinsfile
Makefile
scripts/phase6/failure-drill.sh
scripts/check-phase6-contract.sh
scripts/verify-phase6.sh
docs/implementation/phase-6-failure-recovery.md
docs/runbooks/failure-release-recovery.md
docs/troubleshooting/phase-6-failure-recovery.md
docs/reviews/phase-6-technical-review.md
docs/architecture.md
README.md
```

故障演练脚本放在 `scripts/phase6/`，与现有正常发布脚本 `scripts/ci/` 隔离，避免故障逻辑污染日常发布路径。

## 13. 合同检查与自动验证

### 13.1 静态合同检查

`scripts/check-phase6-contract.sh` 至少检查：

- `RUN_FAILURE_DRILL` 默认值为 `false`；
- 演练阶段存在 `when` 条件和 `input` 审批；
- 演练镜像标签包含 `does-not-exist` 等明确标记；
- 演练脚本不包含删除 Namespace、PVC、Secret 的命令；
- 存在退出捕获和恢复逻辑；
- 报告列表不含敏感文件；
- 正常发布脚本没有被改造成默认故障路径。

### 13.2 本地验证

- Shell 语法和 lint 检查；
- Phase 6 合同检查；
- 既有 Phase 1 至 Phase 5 合同与测试保持通过；
- 文档链接、命令和文件路径检查；
- Git 敏感信息扫描。

### 13.3 真实验收

- 执行一次人工批准的演练构建，确认预期红色并归档完整证据；
- 确认 Helm 自动恢复、服务健康、数据与 PVC 未丢失、监控正常；
- 随后执行一次正常构建，确认全绿；
- 保存两个 Build 编号和关键截图，形成可复述的故障闭环。

## 14. 实施批次与工作量

Phase 6 分为三个实施批次、七项任务：

### 批次一：安全边界与本地逻辑

1. 编写 Phase 6 合同检查；
2. 编写基线、故障注入、诊断和恢复脚本；
3. 完成本地语法、合同和回归检查。

### 批次二：Jenkins 与真实演练

4. 增加 Jenkins 参数、条件和人工审批；
5. 执行真实故障构建，验证失败阻断、自动回滚和证据归档；
6. 执行后续正常构建，验证交付链路恢复。

### 批次三：材料收尾

7. 完成实施记录、Runbook、排障记录、架构更新、技术复核和简历证据整理。

预计工作量约为 Phase 3 的 40%、Phase 4 的 35% 至 45%、Phase 5 的 40% 至 50%。代码量接近 Phase 2，但对状态判断、恢复边界和验收证据的要求更高。

## 15. 风险与控制

| 风险 | 控制措施 |
|---|---|
| 普通构建误触发演练 | 参数默认关闭，仅手动启用，并增加人工审批 |
| 基线原本不健康 | 演练前执行强制基线检查，不健康则拒绝执行 |
| Helm 自动回滚失败 | 退出捕获、诊断归档、按记录 revision 尝试恢复并打印人工命令 |
| 数据或 PVC 被误操作 | 合同检查禁止删除 Namespace、PVC、Secret，不修改数据库凭据 |
| 把预期红灯当成演练失败 | 报告区分预期故障与恢复失败，随后用正常绿色构建闭环 |
| 敏感信息进入归档或 Git | 使用明确归档白名单并执行敏感信息扫描 |
| 故障代码污染正常发布 | 将脚本隔离在 `scripts/phase6/`，正常路径默认跳过 |

## 16. 企业环境差异

企业生产环境通常还会增加：

- 独立 staging 或 pre-production 环境；
- 多人审批、变更单和发布窗口；
- 金丝雀或蓝绿发布；
- 基于 Prometheus SLI/SLO 的自动分析；
- Argo Rollouts、Flagger 等渐进式交付控制器；
- 邮件、聊天软件或事件平台通知；
- 高可用数据库、备份恢复与跨集群方案。

本项目保留失败阻断、回滚、恢复验证和证据归档这些核心思想，但控制复杂度，使其适合非社会员工独立完成、写入简历并在完成后循序学习。

## 17. 完成定义

Phase 6 完成必须同时具备：

- 设计、实施、Runbook、排障和技术复核文档；
- 参数化且默认安全的 Jenkins 演练入口；
- 一次真实的预期红色故障构建；
- Helm 自动回滚和完整恢复证据；
- MySQL 数据及 PVC 保持不变的证据；
- Prometheus 和监控工作负载健康证据；
- 一次演练后的正常绿色构建；
- 全量回归、合同检查和敏感信息扫描通过；
- Git 提交记录与适合简历展示的截图和表述。

## 18. 参考资料

- [Jenkins Pipeline Syntax](https://www.jenkins.io/doc/book/pipeline/syntax/)
- [Helm Upgrade](https://docs.helm.sh/docs/helm/helm_upgrade/)
- [Kubernetes：执行滚动更新与回滚](https://kubernetes.io/docs/tasks/run-application/update-deployment-rolling/)
- [Argo Rollouts Documentation](https://argoproj.github.io/argo-rollouts/)
