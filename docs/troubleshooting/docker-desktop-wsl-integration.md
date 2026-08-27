# Docker Desktop 更新后 Ubuntu WSL 集成中断

## 现象

Docker Desktop 4.88.1 更新后弹出：

```text
WSL integration with distro 'Ubuntu' unexpectedly stopped.
failed to read component versions:
open /opt/docker-desktop/componentsVersion.json: no such file or directory
```

Ubuntu 中运行 `docker` 时提示该发行版没有启用 WSL integration。

## 影响范围与证据

- Windows 侧 Docker Desktop Engine 正常，Client/Server 为 29.7.2；
- `devops-platform-jenkins`、k3d server 和 load balancer 容器仍在运行；
- `docker-desktop` WSL 发行版正常运行；
- Ubuntu 本身可以启动，但 `/opt/docker-desktop` 没有挂载，Ubuntu 内无法正常调用 Docker CLI；
- `/mnt/wsl/docker-desktop` 仍存在，说明故障集中在“用户发行版集成注入”，不是镜像、volume 或 Engine 数据丢失。

因此该提示会阻断项目在 Ubuntu 中使用 `docker`、`make phase*` 和部分 Jenkins/k3d 运维命令，需要恢复；不需要重装 Ubuntu、删除 Docker 数据或执行 factory reset。

## 安全恢复顺序

1. 点击提示框的 **Restart the WSL integration**。
2. 在新 Ubuntu 终端验证 `docker version` 和 `docker ps`。
3. 若仍失败，关闭 Docker Desktop，在 PowerShell 执行 `wsl --shutdown`，再启动 Docker Desktop。
4. 检查 Docker Desktop `Settings -> Resources -> WSL Integration` 中 Ubuntu 已启用并 Apply。
5. 仍失败时再检查 `wsl --version` / `wsl --update`，并使用 Docker Desktop `Gather diagnostics`；不要先卸载、factory reset 或删除 WSL 发行版。

Docker 官方建议使用最新 WSL，最低为 2.1.5，并在 `Settings -> Resources -> WSL Integration` 为目标 WSL 2 发行版开启集成。

## 验收标准

恢复后必须同时满足：

```bash
docker version
docker ps
cd ~/projects/devops-web-platform
make phase4-contract
```

并确认 Jenkins 与 k3d 容器仍存在、项目 Git 工作树和 MySQL PVC 数据未受影响。

## 本次恢复结果

首次点击 **Restart the WSL integration** 后，Ubuntu 中仍提示未启用集成。随后按安全顺序停止 Docker Desktop、执行 `wsl --shutdown` 并重新启动 Docker Desktop，集成恢复：

- Ubuntu 中 `docker` 恢复为 `/usr/bin/docker`；
- Docker Client/Server 均为 29.7.2；
- k3d server 与 load balancer 容器自动恢复；
- Jenkins 容器因本次停止操作处于 Exited，手动 `docker start devops-platform-jenkins` 后恢复为 healthy；
- 未删除镜像、volume、WSL 发行版或 Docker 数据。

结论：这是 Docker Desktop 更新过程中用户发行版集成注入失效，不是项目数据损坏。若以后再次出现，优先复用上述恢复顺序。
