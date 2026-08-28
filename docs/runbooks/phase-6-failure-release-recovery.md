# Phase 6 Runbook：失败发布演练与恢复

## 适用范围

本 Runbook 只适用于个人本机的 WSL2、Docker Desktop、k3d 非生产集群。演练会短暂提交一个不存在的 backend 镜像，禁止在生产、共享集群或包含重要数据的环境直接照搬。

不要在命令、截图或报告中填写 Docker Hub PAT、Jenkins 密码、SSH 私钥口令、kubeconfig 内容、数据库密码或 Kubernetes Secret。

## 一、演练前检查

1. 保持 Docker Desktop、WSL Ubuntu、k3d 集群和 Jenkins 运行。
2. 在新打开的 Ubuntu 终端进入项目：

   ```bash
   cd ~/projects/devops-web-platform
   ```

3. 检查应用和监控：

   ```bash
   make phase5-status
   make phase6-contract
   KUBECONFIG=/tmp/devops-platform-jenkins-kubeconfig \
     BUILD_NUMBER=manual-preflight \
     bash scripts/phase6/failure-drill.sh --preflight
   ```

4. 只有 preflight 成功时才继续。若 Helm 不是 `deployed`、工作负载未 Ready、PVC 未 Bound、应用 API 或 Prometheus Target 不健康，应先解决原有故障，不要启动演练。

## 二、在 Jenkins 启动演练

1. 打开 <http://localhost:8090>，进入 `devops-web-platform/main`。
2. 选择 `Build with Parameters`。
3. 勾选 `RUN_FAILURE_DRILL`，开始构建。
4. 前九个正常阶段成功后，`Failure Drill` 会暂停等待审批。
5. Jenkins 用户 `zing` 确认这是本机非生产集群后，点击 `Run failure drill`。

审批的含义是：明确允许本次构建发布一个不存在的 backend 标签并等待 Helm 自动回滚。它不是输入密码，也不是允许删除数据库或 PVC。

## 三、判读预期红色

演练 Build 设计为红色。必须同时检查以下证据，不能只看颜色：

1. Description 或 Console 包含 `EXPECTED_DRILL_FAILURE`。
2. Console 不包含 `RECOVERY_FAILURE`。
3. `phase6-failure.txt` 或 `kubernetes-events.txt` 包含 `ErrImagePull` / `ImagePullBackOff`。
4. `phase6-recovery.txt` 包含：

   ```text
   result=EXPECTED_DRILL_FAILURE
   rollback_verified=true
   persistence_verified=true
   monitoring_verified=true
   ```

5. 如果出现 `RECOVERY_FAILURE`、任一恢复字段不是 true、报告缺失或本机 verifier 失败，本次不是成功演练，应进入“人工恢复”。

## 四、下载与保留报告

在演练 Build 页面下载或查看以下白名单 artifacts：

- `phase6-baseline.txt`
- `phase6-failure.txt`
- `phase6-recovery.txt`
- `helm-history.txt`
- `kubernetes-events.txt`
- `images.txt`

不要归档或上传 kubeconfig、Docker config、完整环境变量、Secret YAML、Token 或密码。报告用于面试讲解时，也应先检查不含敏感值。

## 五、恢复后本机验收

回到 Ubuntu 终端执行：

```bash
cd ~/projects/devops-web-platform
make phase6-verify
```

预期最后输出 `[phase6-verify] PASS`，并证明 Helm `deployed`、frontend/backend/MySQL Ready、持久化任务为 `completed`、PVC UID 保持、Prometheus Target 为 UP、critical firing alerts 为 0，CRUD 可完成。

如果本机端口 `29090` 被占用，可以使用其他未占用端口：

```bash
PHASE6_PROMETHEUS_PORT=29091 make phase6-verify
```

## 六、运行后续正常绿色构建

1. 再次选择 `Build with Parameters`。
2. 保持 `RUN_FAILURE_DRILL=false`。
3. 运行构建。
4. 预期九个正常阶段和 Post Actions 全绿，`Failure Drill` 跳过，整个 Build 绿色。

这一步证明演练完成后正常交付链路仍然可用。

## 七、自动恢复失败时人工回滚

只有出现 `RECOVERY_FAILURE` 或 verifier 失败时才执行。先从 `phase6-recovery.txt` 的 `manual_rollback_revision`，或从 `phase6-baseline.txt` / `helm-history.txt` 复制健康 revision。不要猜 revision。

```bash
helm rollback devops-platform <从报告复制的健康_REVISION> \
  --kube-context k3d-devops-platform \
  --namespace devops-platform \
  --wait=watcher \
  --timeout 5m
```

随后执行：

```bash
make phase5-status
make phase6-verify
```

若仍失败，保留报告和 `kubectl get pods -n devops-platform`、`kubectl get events -n devops-platform --sort-by=.lastTimestamp`、`helm history devops-platform -n devops-platform` 输出再排查。禁止用 `helm uninstall`、删除 Namespace、PVC、Secret 或整个 k3d 集群代替恢复。
