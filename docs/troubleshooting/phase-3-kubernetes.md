# Phase 3 真实问题记录

本文只记录 Phase 3 实施中实际发生并解决的问题，不为增加简历内容虚构故障。

### k3d 5.9 不支持计划中的 `config process`

**现象：** 原计划用于校验集群配置的 `k3d config process` 命令不存在。

**影响：** 集群创建前的配置解析门禁无法执行。

**证据：** `k3d config --help` 只列出 `init` 和 `migrate`。

**根本原因：** 计划引用了当前 k3d CLI 没有提供的子命令。

**解决办法：** 使用 `k3d config migrate` 对 v1alpha5 文件执行解析和规范化，再交给 `k3d cluster create --config`。

**验证结果：** 配置解析成功，单节点集群创建并进入 Ready。

**预防措施：** 实施计划中的 CLI 语法必须用本机实际版本的 `--help` 验证。

### Phase 2 占用 8080 导致 k3d 创建回滚

**现象：** k3d load balancer 无法绑定 `127.0.0.1:8080`，集群创建失败并回滚。

**影响：** Phase 3 入口无法启动。

**证据：** Phase 2 frontend 容器仍绑定同一个宿主机端口。

**根本原因：** Compose 与 k3d 被设计为复用同一演示地址，不能同时占用端口。

**解决办法：** 正常停止 Phase 2 容器并保留命名卷；在集群创建脚本加入 8080 端口前置检查和明确报错。

**验证结果：** Phase 2 数据卷保留，k3d 成功绑定入口端口。

**预防措施：** 创建集群前先检查端口，不让 Docker 在创建到一半时才暴露冲突。

### Helm 4 废弃 `--atomic`

**现象：** Helm 4 对 `--atomic` 输出弃用提示。

**影响：** 当前仍可执行，但脚本会依赖即将移除的兼容行为。

**证据：** 本机 Helm 4.2.0 明确建议使用 `--rollback-on-failure`。

**根本原因：** 计划沿用了 Helm 3 常见参数。

**解决办法：** 集群基础设施和应用部署统一使用 `--rollback-on-failure --wait=watcher`。

**验证结果：** Helm 安装、失败回滚和重复 upgrade 均通过。

**预防措施：** 固定并记录 Helm 主版本，根据实际 CLI 提示维护脚本。

### frontend 无法解析后端 Service

**现象：** 第一次 Helm 部署时 frontend 进入 CrashLoop，Nginx 报无法解析 upstream `backend`。

**影响：** 页面无法启动，Helm 安装回滚。

**证据：** Phase 2 的 `nginx.conf` 固定使用 `backend:5000`，而最初模板生成的是带 release 前缀的 Service 名称。

**根本原因：** 为复用同一前端镜像，Kubernetes 服务发现契约必须与 Compose 的 DNS 名称一致。

**解决办法：** 在项目专用 namespace 中把后端 ClusterIP Service 固定命名为 `backend`；其他资源继续使用 Helm fullname。

**验证结果：** Nginx Deployment Ready，`/api/items`、`/healthz` 和 `/readyz` 均可经 Ingress 访问。

**预防措施：** 把镜像依赖的服务名当成显式接口，在 Compose 与 Kubernetes 间保持一致或改为运行时模板化。

### F5 NGINX Ingress 拒绝无 Host 规则

**现象：** Ingress 资源存在，但 Controller 事件报告 `spec.rules[0].host: Required value`。

**影响：** 外部路由未生效。

**证据：** Ingress 事件直接指出 Host 必填；为规则加入 `localhost` 后地址被分配。

**根本原因：** 该 Controller 的校验策略不接受原先的 hostless 规则。

**解决办法：** Ingress 显式使用 `host: localhost`，本地入口仍为 `http://localhost:8080`。

**验证结果：** IngressClass 为 `nginx`，页面和 API 路由全部通过。

**预防措施：** 不只检查资源是否被 API Server 接受，还要查看 Controller 事件和实际地址。

### Pod 删除验收读取到正在终止的旧 Pod

**现象：** 自动验收删除 backend 后，Deployment 已创建替代 Pod，但 UID 断言仍读到旧 UID。

**影响：** 自愈成功却被脚本误判为失败。

**证据：** `kubectl delete --wait=false` 后，label selector 同时短暂看到 Terminating 旧 Pod和新 Pod。

**根本原因：** 验收没有等待删除完成，直接读取了最终一致的选择器结果。

**解决办法：** 改为 `--wait=true`，随后按 label 等待新 Pod Ready，再读取 UID。

**验证结果：** backend UID 实测从 `5897eb18` 变为 `78483083`；MySQL Pod 重建也采用相同等待顺序。

**预防措施：** 故障注入脚本必须等待状态转换完成，不能把资源列表顺序当成稳定契约。

### 数据库连接超时长于 readiness Probe 超时

**现象：** MySQL 缩容后 backend 正确变为 NotReady，但 Probe 事件显示超时，Pod 内验收无法观察到 `/readyz=503`。

**影响：** Service 流量隔离生效，但健康检查原因不够明确，自动验收失败。

**证据：** PyMySQL `connect_timeout` 为 3 秒；Kubernetes HTTP Probe 默认 timeout 为 1 秒，最初的 Pod 内请求只等待 2 秒。

**根本原因：** readiness 的观察窗口短于应用完成数据库失败判断所需时间。

**解决办法：** backend readiness Probe 设置 `timeoutSeconds: 5`，Pod 内验收请求同样等待 5 秒；liveness 继续只检查 Flask 进程。

**验证结果：** MySQL 不可用时 Pod 内 `/healthz=200`、`/readyz=503`；Service 移除 NotReady endpoint，外部 `/readyz=503`；数据库恢复后自动回到 200。

**预防措施：** 探针超时必须大于其内部依赖检查的最大预期耗时，并分别设计 liveness 与 readiness。

除以上条目外，尚未观察到其他 Phase 3 故障；后续只补充可复现且有证据的问题。
