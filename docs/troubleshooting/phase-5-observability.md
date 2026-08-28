# Phase 5 可观测性真实故障记录

本文件只记录实施中真正发生的问题，按现象、证据、根因、修复和复验整理。文件不包含密码、Token、kubeconfig 或 Secret 内容。

## 1. WSL 与 Docker 构建无法访问 PyPI

**现象**

完整测试安装新增 `prometheus-client` 时，WSL 外网请求失败，Docker build 同样无法连接 PyPI。

**证据与根因**

应用代码和依赖版本未报解析错误；WSL 与 Docker 构建网络同时失败，属于当时宿主/WSL 网络链路异常，不是 Python 包名或 requirements 文件错误。

**修复**

恢复宿主网络和 Docker Desktop/WSL 网络后重新运行安装。没有取消固定依赖，也没有改用不可信镜像源绕过验证。

**复验**

Jenkins 后续成功安装 `prometheus-client==0.26.0`，19 项 pytest 全部通过，说明依赖声明有效。

## 2. kube-prometheus-stack 镜像拉取较慢

**现象**

首次安装监控栈时，部分 Pod 长时间处于镜像拉取/未 Ready，Helm 等待接近超时。

**根因**

Chart 需要从多个官方 registry 拉取 Prometheus、Grafana、Operator、Alertmanager 和 exporter 镜像；本地网络速度波动使首次冷启动耗时明显高于普通应用镜像。

**修复**

安装脚本保留固定 Chart 版本，增加有界等待和再次检查，不删除业务集群或 PVC。镜像缓存后后续启动明显加快。

**复验**

Helm release `kube-prometheus-stack` Revision 3 为 `deployed`；6 个监控 Pod 全部 Ready，Prometheus 2 Gi 与 Alertmanager 1 Gi PVC 均 Bound。

## 3. Docker Desktop 更新后 WSL 集成意外停止

**现象**

Docker Desktop 更新后弹出 `WSL integration with distro 'Ubuntu' unexpectedly stopped`，诊断中包含 Docker Desktop 组件版本文件暂时缺失。

**根因**

更新过程重启了 Docker Desktop 内部 WSL 代理，Ubuntu 集成没有自动完成恢复；不是项目容器、Kubernetes manifest 或 Ubuntu 文件损坏。

**修复**

在 Docker Desktop 使用 `Restart the WSL integration`，等待 Engine 恢复，再核对 WSL 中 Docker、k3d 节点和现有容器。

**复验**

Docker Engine 正常，k3d 节点 Ready，Jenkins、应用和监控 Pod 均继续运行。该提示已解决，无需跳过 Ubuntu 集成或重建集群。

## 4. Jenkins Quality Check 找不到 Helm 仓库

**现象**

Jenkins Build `#11`、`#12` 的 Checkout 和 19 项 Unit Test 成功，Quality Check 报错：

```text
Error: repo prometheus-community not found
```

后续 Build/Push/Deploy 格子显示失败或跳过。

**根因**

开发者 WSL 已配置 `prometheus-community` Helm 仓库，但 Jenkins Home 是独立环境。Phase 5 合同直接渲染远程 Chart，错误地依赖了未声明的机器级 Helm 仓库状态。

**修复**

`scripts/check-phase5-contract.sh` 在渲染前显式添加/更新官方仓库，固定 Chart `87.21.0`，失败时最多重试 3 次。没有关闭 Quality Check，也没有删除固定版本。

**复验**

先在 Jenkins 容器直接执行合同检查通过，再运行完整本地 Quality Check 通过；提交 `8dd041e` 后 Jenkins Build `#13`、`#14` 九阶段全绿。

## 5. 未记录假想事故

实施中没有发生 Prometheus 数据损坏、Grafana Dashboard 丢失、Alertmanager 无法恢复、监控 PVC 丢失或 RBAC 越权读取 Secret，因此不为这些情况编造“真实故障”。对应操作建议只保存在 Runbook。
