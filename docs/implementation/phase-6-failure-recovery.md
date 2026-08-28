# Phase 6 实施记录：失败发布、自动回滚与恢复验收

## 目标与范围

Phase 6 在现有 Jenkins 正常发布链路之后增加一个默认关闭、仅允许人工启用和批准的 `Failure Drill` 阶段。演练只在本机 WSL2、Docker Desktop 与 k3d 非生产集群中运行，用不存在的 backend 镜像标签制造一次可控发布失败，并验证 Helm 自动回滚、应用恢复、MySQL 数据与 PVC 保持以及 Prometheus 监控恢复。

该阶段验证的是“识别失败发布、保存诊断、恢复服务并证明恢复结果”的初级 DevOps 能力，不声称实现生产级混沌工程、跨集群容灾或零停机高可用。

## 实施结果

1. Jenkins 新增 Boolean 参数 `RUN_FAILURE_DRILL`，默认值为 `false`。
2. 只有用户手动勾选参数后，`Failure Drill` 才会出现；进入阶段后仍需 Jenkins 用户 `zing` 二次批准。
3. 演练使用动态且不会被推送的镜像标签 `failure-drill-${BUILD_NUMBER}-does-not-exist`，不删除 Namespace、PVC、Secret 或 Helm Release。
4. Helm 使用 `--rollback-on-failure --wait=watcher --timeout 5m`，Kubernetes 出现镜像拉取失败后由 Helm 恢复上一健康版本。
5. 演练脚本保存健康基线、故障、恢复、Helm history、Kubernetes events 和镜像清单六类白名单报告。
6. 恢复验收同时检查应用健康、CRUD、持久化任务、MySQL StatefulSet/PVC、Prometheus Target 和 critical 活动告警。
7. 成功恢复的演练由 Jenkins 主动标记为红色并写入 `EXPECTED_DRILL_FAILURE`；恢复异常使用不同的 `RECOVERY_FAILURE` 标识。

## 真实 Evidence / Value

| Evidence | Value | 说明 |
|---|---|---|
| 演练前 Helm revision | `22` | 独立 preflight 时记录的健康 Release revision；preflight 未修改集群 |
| 演练 Build | Jenkins `#17` / `FAILURE` | 前九个正常阶段绿色，`Failure Drill` 红色 |
| 演练结果标识 | `EXPECTED_DRILL_FAILURE: rollback verified` | 证明红色是主动表达“坏版本被拦截”，不是未恢复的事故 |
| 演练基线 Helm revision | `23` | `#17` baseline report 中用于回滚判断的 revision |
| 故障镜像标签 | `zingzin/devops-web-platform-backend:failure-drill-17-does-not-exist` | 未构建、未推送，仅用于触发 `ErrImagePull` / `ImagePullBackOff` |
| 恢复 Build | Jenkins `#18` / `SUCCESS` | 九个正常阶段绿色，`Failure Drill` 默认跳过，整个 Build 绿色 |
| 最终 Helm 状态 | revision `26`, `deployed` | 后续正常发布与最终 verifier 读取到的健康状态 |
| 恢复后 backend 镜像 | `zingzin/devops-web-platform-backend:git-ecbc5217e587` | 与健康主线提交一致的不可变镜像标签 |
| 持久化任务 | ID `24`, status `completed` | 描述更新为 `Survived Phase 6 failed-release rollback`，证明回滚前后数据仍可读写 |
| MySQL PVC | `mysql-data-devops-platform-devops-web-platform-mysql-0` | 状态为 `Bound` |
| MySQL PVC UID | `56ff847d-a6bf-4b82-b891-7346ccf45daf` | UID 前 8 位 `56ff847d`；演练前后相同 |
| Prometheus | backend Target `UP`, critical firing alerts `0` | 证明应用恢复后重新被采集，且没有遗留严重活动告警 |
| 本机最终验收 | `[phase6-verify] PASS` | 应用、监控、持久化和 CRUD 全部通过 |

## Jenkins `#17` 归档证据

演练构建归档以下六个文件：

- `phase6-baseline.txt`
- `phase6-failure.txt`
- `phase6-recovery.txt`
- `helm-history.txt`
- `kubernetes-events.txt`
- `images.txt`

恢复报告记录：

```text
result=EXPECTED_DRILL_FAILURE
rollback_verified=true
persistence_verified=true
monitoring_verified=true
baseline_revision=23
marker_id=24
```

归档文件名和内容经过敏感信息检查，没有 kubeconfig、Docker config、密码、Token、Secret 内容或私钥。

## 红色与绿色构建的含义

- `#17` 红色：一次被人工批准的故障演练。只有 Console/Description 为 `EXPECTED_DRILL_FAILURE`，恢复报告四个结果字段为 true，且本机 verifier 通过时，才可以把它判定为成功演练。
- `#18` 绿色：关闭演练参数后的正常发布。它证明故障演练没有破坏主线交付、应用数据、集群资源或监控。
- 如果出现 `RECOVERY_FAILURE`、恢复报告字段不为 true，或者 `make phase6-verify` 失败，必须按 Runbook 人工处理，不能把红色解释为预期结果。

## 能力边界

本阶段可以如实描述为：在 Jenkins 中设计参数化、人工审批的非生产失败发布演练，使用错误镜像触发 Kubernetes 拉取失败，依赖 Helm 自动回滚，并以应用、数据、PVC 与 Prometheus 证据验证恢复。

本阶段不能描述为：生产级混沌工程、跨地域容灾、数据库备份恢复、零停机高可用或自动化灾难恢复平台。
