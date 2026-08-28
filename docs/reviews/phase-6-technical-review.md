# Phase 6 技术复核

## 复核结论

Phase 6 的实现与已确认设计一致，真实 Jenkins `#17`、`#18`、归档报告和独立 `make phase6-verify` 形成了失败注入、自动回滚、恢复验证和正常交付恢复的证据闭环。该实现适合 DevOps 初级岗位个人简历项目，复杂度可解释，且没有夸大为生产级容灾或混沌工程。

## 逐项对照

| 检查项 | 结论 | 证据与边界 |
|---|---|---|
| 1. 参数是否默认关闭且只允许人工启用？ | PASS | `RUN_FAILURE_DRILL=false`；只有 UserIdCause 且由 `zing` 在 input 步骤批准才运行；SCM 默认构建跳过 |
| 2. 故障是否只使用不存在镜像？ | PASS | `#17` 使用 `zingzin/devops-web-platform-backend:failure-drill-17-does-not-exist`；没有构建或推送该标签，也没有删除资源 |
| 3. Helm 自动回滚是否有真实证据？ | PASS | `#17` failure/events 报告记录镜像拉取失败，recovery 报告记录 `rollback_verified=true`；最终 Helm revision `26` 为 `deployed` |
| 4. 恢复失败是否存在二次保护和人工命令？ | PASS | 脚本安装 EXIT/INT/TERM recovery guard，必要时按 baseline revision 回滚；Runbook 要求从报告复制 revision 并提供有界人工 rollback 命令 |
| 5. MySQL 数据和 PVC 是否保持？ | PASS | 持久化任务 ID `24` 恢复后为 `completed`；PVC `mysql-data-devops-platform-devops-web-platform-mysql-0` UID `56ff847d-a6bf-4b82-b891-7346ccf45daf` 保持、状态 Bound |
| 6. Prometheus Target 与监控工作负载是否恢复？ | PASS | recovery report `monitoring_verified=true`；最终 verifier 显示 backend Target UP、critical firing alerts 0、监控 Pods Ready |
| 7. 报告是否不含凭据？ | PASS | 只归档六个白名单文本报告；文件名和内容扫描未发现 kubeconfig、Docker config、密码、Token、Secret 或私钥 |
| 8. 预期红色后是否有正常绿色构建？ | PASS | `#17` 为带 `EXPECTED_DRILL_FAILURE` 的预期红色；`#18` 九个正常阶段和 Post Actions 绿色，Failure Drill 跳过，Build SUCCESS |
| 9. 简历表述是否没有夸大？ | PASS | 只描述本机非生产集群的错误镜像发布、Helm 回滚、数据/PVC/监控验收；明确排除生产 HA、混沌工程、备份恢复和跨区域容灾 |

## 与设计的差异

没有影响验收目标的功能差异。实施中有两处环境适配：

1. kubectl 子资源权限实时检查使用当前版本支持的 `create pods --subresource=portforward`，权限本身仍严格对应 `pods/portforward` Role 规则。
2. Jenkins 容器使用 `host.docker.internal:8080`，WSL 本机 preflight/verifier 使用 `localhost:8080`；这是两个执行环境的正确入口差异，不改变架构。

## 残余限制

- 单节点 k3d、单副本应用与 local-path PVC，不能证明节点级或存储级高可用。
- 只演练错误 backend 镜像，没有覆盖网络分区、节点宕机、数据库损坏或备份恢复。
- Jenkins Controller 挂载 Docker Socket，适用于受信任的个人本机环境，不是生产级执行隔离。
- 自动回滚依赖 Helm/Kubernetes 当前可用；若控制面或本地 Docker 整体不可用，需要先恢复基础环境。

这些限制与项目“完成可解释的 DevOps 初级简历项目、控制复杂度、后续可沿路线学习”的目标一致。
