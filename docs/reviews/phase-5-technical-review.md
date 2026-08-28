# Phase 5 独立技术复核

## 复核结论

Phase 5 的实现符合已确认设计和“完整、可解释、不过度复杂、适合初级 DevOps 简历项目”的约束。未发现阻止合并的高风险问题。实现形成了指标暴露、自动发现、存储与查询、Dashboard、告警计算、Alertmanager 展示、真实恢复和文档证据的闭环。

本结论基于代码合同、19 项单元测试、集群状态检查和三次真实告警恢复演练，不把仅存在于配置文件但未运行验证的内容算作完成能力。

## 设计符合性

| 检查项 | 复核结果 |
|---|---|
| 固定监控版本 | kube-prometheus-stack Chart 固定为 `87.21.0`，合同检查拒绝漂移 |
| Flask 指标 | `/metrics` 使用标准格式；标签为低基数，不包含动态任务 ID 或配置秘密 |
| 自动发现 | ServiceMonitor 使用明确标签、Namespace 和命名端口，Target 实测 `UP` |
| Dashboard | 九面板 JSON 由 ConfigMap/sidecar 自动供应，不依赖手工导入 |
| 告警规则 | 三条 PrometheusRule 已加载，规则健康 |
| 真实告警 | `BackendTargetMissing` 三次进入 Prometheus Firing 和 Alertmanager 活动列表 |
| 自动恢复 | 三次均恢复原副本、Target UP、规则 Inactive、Alertmanager 活动告警消失 |
| 数据保护 | 验收记录 ID 18、20、22 保留；MySQL PVC UID 前缀始终为 `56ff847d` |
| Jenkins 边界 | 日常发布只管理业务 Namespace 的监控对象，不读取 monitoring Secret，也未授予 cluster-admin |
| 本机访问 | 三个监控页面仅通过 `127.0.0.1` 临时端口转发，不创建公网入口 |

## 验证证据

- `make phase4-contract`：通过。
- `make phase5-contract`：通过，并验证监控关闭/开启两种应用 Chart 形状以及固定上游 Chart。
- 后端单元测试：`19 passed`。
- `make phase5-status`：六类监控工作负载 Running，Prometheus 2 Gi 与 Alertmanager 1 Gi PVC Bound，应用工作负载 Ready。
- `make phase5-verify`：三次通过；最后一次 Firing 为 `2026-08-28T03:49:57Z`，Resolved 为 `2026-08-28T03:51:28Z`。
- Jenkins Build `#13`、`#14`：加入 Phase 5 资源后的流水线全部绿色；最终文档合并后仍需用 GitHub `main` 再跑一次发布验收。

## 已知限制与接受理由

1. 监控组件是单副本，PVC 使用本机 local-path，保留时间短。它适合个人实验和故障演练，不包装成生产级高可用。
2. Alertmanager 未连接邮箱或聊天软件。页面内真实告警足以证明告警链路，同时避免引入个人账号、SMTP/API Token 和额外排障面。
3. 监控首次安装需要集群管理员创建 CRD、ClusterRole 和 Webhook；Jenkins 普通发布仍维持 Namespace 最小权限，这是合理的职责分离。
4. Helm Chart 版本已固定，但首次准备官方仓库仍依赖外网。CI 脚本已加入仓库准备和有界重试，网络完全不可用时会明确失败而非静默降级。
5. Phase 4 的两个 Jenkins 凭据位于 System / Global，插件集合也未逐项锁定版本。这是此前已记录的个人环境限制，不由 Phase 5 扩大权限或掩盖。

## 建议的后续方向

下一阶段优先做一次可控的失败发布与回滚演练，并把 Jenkins、Helm、Kubernetes、Prometheus 和 Alertmanager 证据串成面试可讲述的事件过程。暂不增加日志平台、链路追踪、多集群或外部通知，以免项目超出初级岗位可解释范围。
