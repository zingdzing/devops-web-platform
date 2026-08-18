# Phase 2 真实问题记录

本文只记录 Phase 2 实施中实际复现并解决的问题，不为展示复杂度而虚构故障。

### 隔离工作区没有可复用的 Python 虚拟环境

**现象：** 依赖安装命令返回 `.venv/bin/python: No such file or directory`。

**影响：** 无法在 Phase 2 工作区运行 pytest 和安装 Gunicorn。

**证据：** `ls` 同时确认隔离工作区和原项目路径都不存在 `.venv`。

**根本原因：** `.venv` 按设计被 Git 忽略，且此前环境没有留下可以链接的虚拟环境；隔离 Git worktree 不会自动复制忽略文件。

**解决办法：** 在 Phase 2 工作区执行 `python3 -m venv .venv`，随后安装 `app/backend/requirements-dev.txt`。

**验证结果：** Gunicorn 26.0.0 与 pytest 9.1.1 安装成功，14 个后端测试全部通过。

**预防措施：** 新 worktree 初始化时显式检查 `.venv` 和 `.env`，不要假定 Git 工作区会携带本地状态。

### 独立执行 `nginx -t` 无法解析 Compose 服务名

**现象：** 前端镜像构建成功，但独立运行 `nginx -t` 返回 `host not found in upstream "backend"`。

**影响：** 无法用原计划命令区分 Nginx 语法问题和服务发现环境缺失。

**证据：** 配置中的 upstream 为 `backend:5000`；加入临时主机映射后，同一镜像的 `nginx -t` 成功。

**根本原因：** `backend` 是 Compose 网络提供的 DNS 服务名，独立 `docker run` 容器不在该网络中。

**解决办法：** 静态测试使用 `docker run --add-host backend:127.0.0.1 --entrypoint nginx ... -t`；集成测试再通过真实 Compose 网络验证代理请求。

**验证结果：** Nginx 配置语法检查成功，Compose 中 `/healthz`、`/readyz` 和 `/api/items` 代理全部通过。

**预防措施：** 对依赖服务发现的配置，分开执行“语法验证”和“真实网络集成验证”。

### Compose 5.4.0 查询未发布端口返回 `invalid IP:0`

**现象：** 对 backend 和 mysql 执行 `docker compose port` 时输出 `invalid IP:0`，而不是安静地表示没有宿主机映射。

**影响：** 原计划的端口安全断言无法可靠执行。

**证据：** 两个服务的 UID 和健康接口均正常；`docker inspect` 显示 backend、mysql 的 `HostConfig.PortBindings` 为 `{}`，frontend 则明确绑定 `127.0.0.1:8080`。

**根本原因：** 当前 Docker Compose 5.4.0 对未发布端口的 `compose port` 查询行为不适合用作空结果断言，容器本身并未错误映射端口。

**解决办法：** 验收脚本通过 Compose 获取容器 ID，再使用 `docker inspect --format '{{json .HostConfig.PortBindings}}'` 检查实际绑定。

**验证结果：** 两次完整 Phase 2 验收均确认 backend、mysql 为 `{}`，frontend 只绑定 `127.0.0.1:8080`。

**预防措施：** 安全边界验收优先检查 Docker 的最终容器状态，不依赖面向用户展示的快捷命令行为。

### 复合 PowerShell 到 WSL 检查命令被错误拆分

**现象：** 包含嵌套 `$()`、引号和带空格正则的计划检查命令把 `grep` 参数拆成多个文件名。

**影响：** 文档提交前检查中止，但文件没有丢失，也没有产生半提交。

**证据：** Git 状态显示计划文件仍为未跟踪；把任务数与步骤数检查拆成原子命令后分别得到 8 和 45。

**根本原因：** PowerShell、`wsl.exe` 和 Bash 多层解析共同处理同一段复合字符串。

**解决办法：** 将检查拆成不含嵌套命令替换的原子命令；长期逻辑写入仓库中的 Bash 脚本。

**验证结果：** 计划通过占位符、安全、覆盖度和 Git 格式检查后成功提交。

**预防措施：** 自动验收集中到 `scripts/verify-phase2.sh`，从 PowerShell 只调用脚本入口。
