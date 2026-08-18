# Phase 0：环境与代码仓库

## 1. 阶段目标

准备一个能够完成本地容器化、Kubernetes、Helm 和 GitHub 协作的 Windows + WSL 开发环境，并创建公开项目仓库。Phase 0 只安装和验证基础工具，不提前部署 Nginx、MySQL、Jenkins、Prometheus 或 Grafana 工作负载。

## 2. 最终架构

```text
Windows 11
├── Docker Desktop（WSL 2 后端）
├── Windows Terminal / PowerShell
└── WSL Ubuntu
    ├── Git 与 SSH
    ├── Python
    ├── Docker CLI / Compose
    ├── kubectl / Helm / k3d
    └── ~/projects/devops-web-platform
```

GitHub 和 Docker Hub 均启用了基于 Google Authenticator 的 TOTP 两步验证。SSH 私钥只保存在 WSL 用户目录，GitHub 仓库只接收对应公钥。

## 3. 新增或修改的文件

- `.gitignore`：排除本地密码、私钥、虚拟环境、日志和运行数据。
- `.env.example`：保存不可用于真实部署的本地示例变量。
- `scripts/check-prerequisites.sh`：自动检查项目所需工具。
- `Makefile`：通过 `make check` 统一调用环境检查。
- `README.md` 与 `docs/architecture.md`：记录项目目标与阶段路线。

## 4. 实际执行命令

```bash
wsl -d Ubuntu
cd ~/projects/devops-web-platform
make check
git status
git push -u origin main
```

首次使用受口令保护的 SSH 私钥时，在用户自己的 WSL 终端执行：

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
```

口令由用户在本地输入，不写入命令、文档或仓库。

## 5. 验证结果

2026-08-18 实际验证的主要环境为：Docker Engine 29.7.2、Docker Compose 5.4.0、kubectl v1.36.1、Helm v4.2.0、k3d v5.9.0、WSL Ubuntu 26.04、Git 和 Python 3.14。`make check` 的 15 项检查全部通过，SSH 推送成功，公开仓库为 `github.com/zingdzing/devops-web-platform`。

## 6. 简历能力映射

- Windows、WSL 2 与 Linux 命令行环境管理。
- Git 分支、提交、SSH 密钥和 GitHub 远程仓库使用。
- Docker、Compose、kubectl、Helm 与 k3d 工具链准备。
- `.gitignore`、本地环境变量和 2FA 基础安全实践。

## 7. 与下一阶段的关系

Phase 1 在该 WSL 仓库中实现最小业务应用；Docker Desktop 为本地 MySQL 和后续多容器编排提供运行环境。
