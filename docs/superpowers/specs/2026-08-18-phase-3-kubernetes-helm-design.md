# Phase 3 Kubernetes 编排与 Helm 标准化部署设计

## 1. 阶段目标

Phase 3 将 Phase 2 中由 Docker Compose 管理的前端、后端和 MySQL 三容器系统迁移到本地 Kubernetes 集群，并使用 Helm 统一安装、升级和验证。

本阶段重点不是增加业务功能，而是证明能够把已经验证过的容器镜像交给 Kubernetes 管理，完成服务发现、统一入口、健康检查、故障自动恢复和数据持久化。

完成后，项目应当可以通过少量稳定命令创建集群、导入镜像、部署应用、执行真实 CRUD 和故障恢复验收。所有命令、验证证据与真实排错过程继续保存在仓库中。

## 2. 与项目目标的匹配结论

该阶段满足项目的核心约束：

- **简历价值明确**：覆盖 k3d、Kubernetes、Deployment、StatefulSet、Service、Ingress、ConfigMap、Secret、PVC、Probe、资源限制和 Helm。
- **规模适中**：使用单节点本地集群，每个业务组件一个副本；不加入 TLS、HPA、多环境、云平台或生产级高可用。
- **完整可验证**：不仅创建 YAML，还验证页面、CRUD、Pod 自愈、依赖故障语义和 MySQL Pod 重建后的数据保留。
- **适合后续学习**：Kubernetes 资源与 Phase 2 的三个容器一一对应，Phase 4 可以直接把本地镜像导入替换为 Jenkins 构建和 Docker Hub 发布。
- **描述保持诚实**：一个副本只能证明自动恢复，不能声称实现生产级高可用；PVC 只保证 Pod 重建后保留数据，不保证删除整个 k3d 集群后仍保留。

## 3. 方案选择

### 3.1 本地集群

采用 k3d 在 Docker Desktop 中运行单节点 K3s 集群：

```text
Windows
  |
  v
Docker Desktop
  |
  v
k3d containers
  |
  v
K3s / Kubernetes
```

选择 k3d 的原因是它运行真实、符合标准的 Kubernetes，同时比多虚拟机集群占用更少资源，适合本地开发、CI 和初学者复现。

不采用以下方案：

- 多虚拟机 kubeadm：会把阶段重点转向节点、证书和 CNI 安装，超过当前简历项目范围。
- Docker Desktop 内置 Kubernetes：可用，但集群创建、销毁、端口映射和自动化复现不如 k3d 明确。
- Minikube：同样可行，但项目已经使用 Docker Desktop，k3d 与本地镜像导入和后续 CI 衔接更直接。

### 3.2 外部入口

禁用 K3s 默认 Traefik，通过 Helm 安装仍在维护的 F5 NGINX Ingress Controller 开源版本，并使用标准 Kubernetes Ingress 资源。

不使用已经于 2026 年 3 月退役的社区 `kubernetes/ingress-nginx`。本阶段也不采用 Gateway API，因为 GatewayClass、Gateway 和 HTTPRoute 会增加当前阶段的概念数量；它保留为后续扩展方向。

NGINX Ingress Controller 属于集群基础设施，安装在独立命名空间；业务 Helm Chart 不把控制器作为子 Chart，从而保持入口控制器和业务应用生命周期分离。实施时固定经过验证的 Chart 与控制器版本，不使用浮动版本。

### 3.3 镜像交付

Phase 3 使用 Docker 在本地构建带明确 Phase 3 标签的前端和后端镜像，再通过 `k3d image import` 导入集群。工作负载使用 `IfNotPresent`，不使用部署意义上的 `latest`。

本阶段不引入 Docker Hub 或私有镜像仓库。Phase 4 再将该步骤替换为 Jenkins 构建、推送和按不可变标签部署，从而把 Kubernetes 编排与 CI/CD 两个学习目标分开。

## 4. 总体架构与请求流

```text
Browser
  |
  | http://127.0.0.1:8080
  v
k3d load balancer / port mapping
  |
  v
F5 NGINX Ingress Controller
  |
  +-- / --------------------> frontend Service
  |                              |
  |                              v
  |                         frontend Deployment
  |                              |
  |                              v
  |                         unprivileged Nginx
  |
  +-- /api, /healthz,
      /readyz ----------------> backend Service
                                  |
                                  v
                             backend Deployment
                                  |
                                  v
                           Gunicorn + Flask
                                  |
                                  v
                              mysql Service
                                  |
                                  v
                            MySQL StatefulSet
                                  |
                                  v
                                 PVC
```

Ingress 使用前缀路径。更具体的 `/api`、`/healthz` 和 `/readyz` 指向后端，兜底 `/` 指向前端。浏览器继续使用相对 `/api` 路径，因此前端代码不写死后端地址。

只有 k3d 入口映射到宿主机 `127.0.0.1:8080`。前端、后端和 MySQL Service 均使用集群内部访问方式，不单独暴露 NodePort 或宿主机端口。

## 5. Kubernetes 资源设计

### 5.1 命名空间

- `nginx-ingress`：NGINX Ingress Controller 等入口基础设施。
- `devops-platform`：前端、后端、MySQL 和应用配置。

业务命名空间由 `helm upgrade --install --create-namespace` 创建，不把 Namespace 对象放进业务 Chart，避免卸载 Release 时产生不清晰的命名空间所有权。

### 5.2 前端

- 一个副本的 Deployment。
- 一个 ClusterIP Service，将集群内 8080 转发到前端 Pod。
- 使用 Phase 2 已有的非特权 Nginx 镜像。
- 以非 root 用户运行，并保留现有只读静态资源职责。
- Pod 删除后由 Deployment 自动补建；本阶段不声称具备零中断高可用。

### 5.3 后端

- 一个副本的 Deployment。
- 一个 ClusterIP Service，将集群内 5000 转发到 Gunicorn。
- 继续以非 root 用户运行。
- 数据库地址使用稳定的 `mysql` Service DNS 名称，不引用 Pod IP。
- 普通配置来自 ConfigMap，数据库凭据来自预先创建的 Kubernetes Secret。

### 5.4 MySQL

- 一个副本的 StatefulSet。
- 一个供后端服务发现和 StatefulSet 网络身份使用的 Service。
- 由 StatefulSet `volumeClaimTemplates` 创建一个 PVC 并挂载到 `/var/lib/mysql`，显式采用 Retain 保留策略。
- 使用 K3s 默认 local-path StorageClass，初始申请 1Gi；实施时根据实际镜像启动和写入测试校正。
- 初始化 SQL 作为 Chart 内文件打包，通过 ConfigMap 挂载到 MySQL 初始化目录，并增加自动检查确保它与 Phase 2 的 `app/database/init.sql` 保持一致。
- PVC 验证范围是 MySQL Pod 删除重建，删除整个 k3d 集群不在数据保留承诺内。

### 5.5 配置与 Secret

ConfigMap 保存非敏感配置，例如：

- `DB_HOST`
- `DB_PORT`
- `DB_NAME`

Secret 保存：

- `DB_USER`
- `DB_PASSWORD`
- MySQL root 密码（如果镜像初始化需要）

真实 Secret 不写入 Chart、`values.yaml` 或 Git。部署脚本在前置检查通过后，从被 Git 忽略的本地 `.env` 幂等创建或更新 Secret。文档明确说明 Kubernetes Secret 默认主要提供编码与访问边界，不等同于静态加密保险箱。

### 5.6 资源请求与限制

初始实验值如下，最终值以本机验证为准：

| 组件 | CPU request | CPU limit | memory request | memory limit |
|---|---:|---:|---:|---:|
| frontend | 25m | 100m | 32Mi | 64Mi |
| backend | 50m | 250m | 64Mi | 256Mi |
| mysql | 100m | 500m | 256Mi | 512Mi |

这些值用于展示基本资源治理并控制本地资源占用，不宣称是生产容量规划结果。

## 6. 健康检查与故障语义

### 6.1 前端

- startup/readiness：HTTP GET `/`。
- liveness：HTTP GET `/`。

### 6.2 后端

- startup：HTTP GET `/healthz`，为 Gunicorn 启动留出时间。
- liveness：HTTP GET `/healthz`，只判断进程是否能够响应。
- readiness：HTTP GET `/readyz`，确认数据库依赖可用。

MySQL 不可用时，后端 `/healthz` 保持 200，`/readyz` 返回 503。Kubernetes 因此停止把业务流量发送给未就绪 Pod，但不会因依赖短暂故障反复重启正常的后端进程。

### 6.3 MySQL

- startup/liveness 用于判断 MySQL 进程是否启动并能够响应。
- readiness 使用数据库账号执行 `SELECT 1`，验证真实认证和查询能力。

Phase 2 已证实 `mysqladmin ping` 在密码错误时仍可能成功，因此它不能单独作为数据库业务就绪依据。Phase 3 将进程存活与认证查询能力分开检查。

## 7. Helm Chart 与文件边界

```text
deploy/
├── k3d/
│   └── cluster.yaml
└── helm/
    └── devops-web-platform/
        ├── Chart.yaml
        ├── values.yaml
        ├── values.schema.json
        ├── files/
        │   └── init.sql
        └── templates/
            ├── _helpers.tpl
            ├── configmap.yaml
            ├── frontend-deployment.yaml
            ├── frontend-service.yaml
            ├── backend-deployment.yaml
            ├── backend-service.yaml
            ├── mysql-init-configmap.yaml
            ├── mysql-service.yaml
            ├── mysql-statefulset.yaml
            ├── ingress.yaml
            └── NOTES.txt

scripts/
├── create-phase3-cluster.sh
├── deploy-phase3.sh
├── stop-phase3.sh
└── verify-phase3.sh
```

- `cluster.yaml` 固定集群名称、节点数量、入口端口和禁用 Traefik 的参数。
- `values.yaml` 提供镜像、标签、端口、资源限制和存储大小等非敏感默认值。
- `values.schema.json` 在渲染前捕获缺失字段、错误类型和非法空值。
- `templates/` 只包含业务应用资源，不捆绑 NGINX Ingress Controller。
- `create-phase3-cluster.sh` 创建可重复的集群并安装固定版本入口控制器。
- `deploy-phase3.sh` 执行前置检查、构建和导入镜像、创建 Secret、Helm lint/template/upgrade 及等待就绪。
- `stop-phase3.sh` 默认停止 k3d 集群以保留工作负载和 PVC；卸载 Release、删除 PVC 和删除集群使用独立且明确标注影响的命令。
- `verify-phase3.sh` 执行完整功能、故障和恢复验收。
- Makefile 提供 `phase3-cluster-create`、`phase3-deploy`、`phase3-verify`、`phase3-status` 和显式清理入口。

脚本使用严格模式并在注册清理 trap 前完成工具和配置前置检查，避免 Phase 2 曾出现的“前置检查失败却触发有副作用 cleanup”。破坏性清理命令必须独立、显式，并在文档中说明数据影响。

## 8. 部署与日常操作流程

首次部署：

1. 检查 Docker、k3d、kubectl、Helm、curl、Git 和必要环境变量。
2. 创建单节点 k3d 集群并确认 Kubernetes API 可用。
3. 在 `nginx-ingress` 命名空间安装固定版本 NGINX Ingress Controller。
4. 构建前端和后端 Phase 3 镜像。
5. 将镜像导入 k3d 集群。
6. 从本地 `.env` 创建或更新应用 Secret。
7. 执行 `helm lint` 和 `helm template`。
8. 使用 `helm upgrade --install --atomic --wait` 部署业务 Chart。
9. 等待 Deployment、StatefulSet 和 Ingress Controller 就绪。
10. 通过 `127.0.0.1:8080` 执行页面与 API Smoke Test。

重复部署使用同一条 Helm upgrade/install 路径，必须保持幂等。常用观察命令写入 Runbook，包括查看 Pod、Service、Ingress、事件、日志、Probe 和 PVC。

## 9. 自动验收

新增 `make phase3-verify`，至少验证：

1. 所需 CLI 和 Docker Desktop 可用。
2. k3d 集群存在且 Kubernetes 节点 Ready。
3. K3s 默认 Traefik 未部署。
4. F5 NGINX Ingress Controller 就绪且 IngressClass 正确。
5. `helm lint`、values schema 校验和 `helm template` 通过。
6. Helm Release 安装或升级成功，所有业务 Pod Ready。
7. 首页可以通过唯一入口 `127.0.0.1:8080` 访问。
8. 经 Ingress 完成任务新增、查询、修改和删除。
9. 前端和后端容器以非 root 用户运行。
10. 前端、后端和 MySQL 没有额外宿主机端口或 NodePort。
11. 删除 backend Pod 后，Deployment 自动创建替代 Pod并恢复 Ready。
12. 暂停 MySQL 工作负载期间，后端 `/healthz` 为 200、`/readyz` 为 503；恢复后 `/readyz` 回到 200。
13. 写入持久化测试数据、删除 MySQL Pod并等待恢复后，数据仍然存在。
14. 对同一 Release 再次执行 Helm upgrade 成功。
15. Git 跟踪文件不包含 `.env`、真实 Secret、私钥、Token、恢复码或 kubeconfig。
16. 所有 Bash 脚本通过 ShellCheck，现有 pytest 与 Phase 1/2 回归检查不被破坏。

验收脚本只清理由它创建的临时测试数据和临时状态，不默认删除用户 PVC、集群或已有业务数据。若验收中断，trap 负责恢复被缩放的工作负载，但不执行扩大范围的清理。

## 10. 安全与网络边界

- 真实凭据只来自被 Git 忽略的本地配置，不出现在命令输出、验收日志或文档中。
- Helm 模板和 `values.yaml` 不保存真实密码。
- kubeconfig 不提交 Git。
- 前端和后端继续以非 root 用户运行；MySQL 使用官方镜像既定运行用户。
- 入口只绑定 `127.0.0.1:8080`，避免本地实验服务默认暴露给局域网。
- ClusterIP 只表示服务不直接暴露到集群外。本阶段不增加 NetworkPolicy，因此不宣称已经实现 Pod 间强网络隔离。
- NGINX Ingress Controller 和应用位于不同命名空间，但命名空间划分本身也不等于网络隔离。
- 基础镜像、K3s、NGINX Ingress Controller Chart 和应用 Chart 版本均固定到经过验证的版本，不使用浮动 `latest`。

## 11. 文档与学习证据

实施过程中新增并维护：

```text
docs/implementation/phase-3-kubernetes.md
docs/troubleshooting/phase-3-kubernetes.md
docs/runbooks/phase-3-operations.md
docs/reviews/phase-3-independent-review.md
```

- 实施文档记录目标、最终架构、实际命令、验证结果、简历能力映射和与 Phase 4 的关系。
- Troubleshooting 只记录实际发生的问题，使用“现象、影响、证据、根因、解决、验证、预防”格式，不预先编造故障。
- Runbook 保存启动、状态检查、日志、Pod 故障、数据库恢复、Helm 升级和保守停止步骤。
- 完成实现和本地验收后，再使用独立子代理进行只读技术审查；审查发现、修正和接受的残余风险写入仓库。

README 和架构文档只有在自动验收通过后才把 Phase 3 标记为完成，不提前宣称 Kubernetes、Ingress 或 Helm 能力已经实现。

## 12. 明确不做的内容

Phase 3 不加入：

- Jenkins、GitHub Webhook 或自动流水线。
- Docker Hub 自动推送或私有镜像仓库。
- Prometheus、Grafana 或 Alertmanager。
- TLS、证书管理和公网域名。
- HPA、MySQL 主从、多控制平面或生产级高可用。
- Gateway API、Service Mesh、NetworkPolicy 或多租户隔离。
- 多套开发、测试、生产 values。
- 集群删除后的存储保留和自动数据库备份。
- Terraform、Ansible、Argo CD、Harbor 或云平台。

这些内容不是遗漏，而是为了让当前阶段可以独立实现、验证、解释和排错。

## 13. 完成标准

- 新环境按照 README 能创建本地集群并部署应用。
- Traefik 未启用，F5 NGINX Ingress Controller 正常处理标准 Ingress。
- 前端、后端和 MySQL 工作负载全部 Ready。
- 页面和完整 CRUD 通过统一入口可用。
- ConfigMap、Secret、Service、Ingress、StatefulSet、PVC、Probe 和资源限制均经过实际验证。
- 删除 backend Pod 后能够自动补建并恢复服务。
- MySQL 不可用时健康语义正确，恢复后业务自动恢复。
- 删除 MySQL Pod 后测试数据保留。
- Helm lint、template、install、重复 upgrade 和自动验收全部通过。
- Phase 0、1、2 的测试与验收不因迁移而回归失败。
- Phase 3 实施、排错、Runbook 和独立审查文档齐全。
- README 只描述已经验证的能力，所有变更通过检查并推送 GitHub。

## 14. 参考依据

- [Kubernetes Overview](https://kubernetes.io/docs/concepts/overview/)
- [K3s Documentation](https://docs.k3s.io/)
- [k3d Documentation](https://k3d.io/)
- [Kubernetes ingress-nginx retirement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [F5 NGINX Ingress Controller Helm installation](https://docs.nginx.com/nginx-ingress-controller/install/helm/open-source/)
- [Kubernetes Gateway API introduction](https://gateway-api.sigs.k8s.io/guides/getting-started/introduction/)
