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

### `mysqladmin ping` 不验证密码是否正确

**现象：** 在 MySQL 容器内使用明确错误的 root 密码执行 `mysqladmin ping`，命令仍返回退出码 0。

**影响：** Compose 可能把数据库标为 healthy，但应用账号或密码与已有命名卷不一致时，`/readyz` 和 CRUD 仍不可用。

**证据：** 错误密码的 `mysqladmin ping` 实测退出 0；错误密码执行真实 `SELECT 1` 则返回非 0。

**根本原因：** `mysqladmin ping` 的职责是确认服务端进程可响应，即使认证失败也能证明服务器存活，不能代表账号可用。

**解决办法：** MySQL healthcheck 改为使用环境中的 root 密码执行 `SELECT 1`；`make phase2-up` 在 Compose `--wait` 后额外请求 `/readyz`。

**验证结果：** 错误密码 `SELECT 1` 被拒绝；正确配置下三个服务 healthy，`make phase2-up` 和完整 Phase 2 验收通过。

**预防措施：** 区分“进程存活”和“业务就绪”；需要验证凭据时执行最小真实查询。

### 验收前置失败触发了不必要的 cleanup

**现象：** 旧脚本在检查 `.env`、curl 和 Docker 前注册 EXIT trap；前置失败也会尝试启动 MySQL并等待 readiness。

**影响：** 简单配置错误可能延迟约两分钟，并改变用户原本停止的容器状态。

**证据：** 独立审查沿着 trap 和 cleanup 调用路径确认该行为；修正后从没有 `.env` 的 `/tmp` 调用脚本，立即报错，MySQL 前后状态均为 `running`。

**根本原因：** cleanup 没有区分“脚本主动停止了 MySQL”和“前置检查尚未开始操作容器”。

**解决办法：** 前置检查使用不调用 Compose 的 `preflight_fail`；检查完成后才注册 trap，并用 `mysql_stopped_by_verifier` 记录是否需要恢复 MySQL。

**验证结果：** 缺 `.env` 测试立即退出且不改变容器状态，正常故障注入仍能恢复数据库。

**预防措施：** 清理逻辑只撤销脚本自己完成的状态变更，并为前置失败建立单独回归测试。

### 页面阶段标识落后于实际部署

**现象：** 三容器系统已经完成，但页面仍显示 `PHASE 1` 和 Phase 1 技术栈。

**影响：** 功能不受影响，但演示截图和仓库文档不一致。

**证据：** `app/frontend/src/index.html` 的 meta、页眉和页脚均包含 Phase 1；独立审查在运行态与源文件对照时发现。

**根本原因：** Phase 2 复用了 Phase 1 静态页面，但容器化完成后没有同步更新展示文本。

**解决办法：** 页面改为 Phase 2，并展示 Nginx、Gunicorn/Flask、MySQL 和 Docker Compose。

**验证结果：** 重建前端镜像后，`http://127.0.0.1:8080` 返回 `DEVOPS WEB PLATFORM · PHASE 2`。

**预防措施：** 每个阶段最终门禁同时检查运行功能和用户可见的阶段标识。
