# Phase 6 排障记录

## 1. Jenkins 首次没有 `Build with Parameters`

- **现象**：Jenkinsfile 已增加参数，但 Job 页面仍只显示 `Build Now`。
- **原因**：Jenkins 需要先加载一次新的 Pipeline 定义，才会把参数写入 Job 配置。
- **处理**：先运行一次默认构建；新定义加载后使用 `Build with Parameters`。第一次构建保持 `RUN_FAILURE_DRILL=false`，不会制造故障。

## 2. `Failure Drill` 红色不一定表示恢复失败

- **现象**：前九个阶段绿色，`Failure Drill` 红色，整个 Build 红色。
- **原因**：成功演练后 Pipeline 主动抛出 `EXPECTED_DRILL_FAILURE`，让失败发布在历史中保持显眼。
- **处理**：检查 Build Description/Console、六份 artifacts 和 `make phase6-verify`。只有 `EXPECTED_DRILL_FAILURE`、四个恢复字段为 true 且 verifier PASS 才是预期红色；`RECOVERY_FAILURE` 才表示恢复异常。

## 3. 演练在 Helm 阶段等待约五分钟

- **现象**：批准后长时间停留在 `Failure Drill`，并非立即红色。
- **原因**：Helm `--timeout 5m` 会等待 Kubernetes 尝试拉取不存在镜像并产生 `ErrImagePull` / `ImagePullBackOff`，随后执行 `--rollback-on-failure`。人工审批等待时间也会显示在阶段耗时附近。
- **处理**：不要重复点击构建或强制停止。等待有界 timeout；结束后查看 events、Helm history 和 recovery report。

## 4. Prometheus 临时端口冲突

- **现象**：preflight 或 verifier 无法绑定 `127.0.0.1:29090`。
- **原因**：已有 port-forward 或其他进程占用端口。
- **处理**：关闭旧 port-forward，或运行 `PHASE6_PROMETHEUS_PORT=29091 make phase6-verify`。脚本退出时会清理自己创建的临时 port-forward。

## 5. monitoring Secret 权限返回 `no`

- **现象**：`kubectl auth can-i get secrets -n monitoring` 返回 `no`。
- **原因**：这是最小权限设计的正确结果。Jenkins 只需要观察 Pods/Services/Endpoints 和建立临时 Pod port-forward，不应读取 Grafana 密码等 Secret。
- **处理**：不要扩权。只有 Pods 观察与 `create pods --subresource=portforward` 应为 `yes`，Secret、资源修改和 Node 访问应保持 `no`。

## 6. port-forward RBAC 检查语法造成误判

- **现象**：`kubectl auth can-i create pods/portforward` 返回 `no`，尽管 Role 已包含 `pods/portforward`。
- **原因**：当前 kubectl 的正确子资源检查语法是 `create pods --subresource=portforward`。
- **处理**：修正实时权限检查命令，并保留合同对 Role 资源 `pods/portforward` 的静态检查；不要为解决语法误判增加多余权限。

## 7. WSL 本机与 Jenkins 容器的应用地址不同

- **现象**：WSL 中访问 `host.docker.internal:8080` 超时，但浏览器和 `localhost:8080` 正常。
- **原因**：Jenkins 运行在 Docker 容器内，需要通过 `host.docker.internal` 访问宿主；WSL 本机验收应使用 `localhost`。
- **处理**：Jenkins 演练保持默认容器地址；本机 preflight 使用 `PHASE6_APPLICATION_URL=http://localhost:8080`。不要把两种运行环境的入口混用。

## 8. 独立工作树 Python 环境缺少指标依赖

- **现象**：复用旧 `.venv-ci` 时测试提示缺少 `prometheus-client`。
- **原因**：旧虚拟环境早于 Phase 5 创建，依赖内容落后于锁定的 requirements。
- **处理**：在独立工作树按锁定 requirements 创建新的 `.venv` 后重新运行测试，不修改应用依赖版本来掩盖环境漂移。

## 9. PowerShell 到 WSL 的多层引号被拆开

- **现象**：含反引号、变量或复杂引号的组合检查在 PowerShell→WSL 过程中被提前解释，命令没有实际检查目标文件。
- **原因**：PowerShell、`wsl.exe` 与 Bash 各自处理一层转义。
- **处理**：把文本检查和 Git/WSL 检查拆开，或使用不含特殊字符的固定字段；遇到失败后重新运行明确的验证命令，不把未执行的命令当成通过。
