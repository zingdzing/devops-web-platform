# Phase 1 最小业务应用设计

## 1. 目标与范围

阶段 1 实现一个可在 WSL Ubuntu 中直接运行的“运维任务清单”。该阶段只建设最小业务闭环，用于验证 Flask、MySQL、前端交互、健康检查和自动化测试；容器化整个应用留到阶段 2。

完成后必须能够：

1. 新增、查询、修改和删除运维任务。
2. 通过静态页面操作上述功能。
3. 使用 `/healthz` 判断 Flask 进程是否存活。
4. 使用 `/readyz` 判断 Flask 是否能够连接 MySQL。
5. 在 MySQL 停止时让 `/readyz` 返回 HTTP 503，并在 MySQL 恢复后自动恢复。
6. 通过 pytest 验证核心接口、参数校验和错误响应。

阶段 1 不加入用户登录、权限、分页、搜索、消息队列、缓存、ORM、Prometheus 指标或 Docker Compose。

## 2. 技术方案

- Python 3.14
- Flask
- PyMySQL
- MySQL 8.4 LTS 容器
- HTML、CSS、原生 JavaScript
- pytest

后端使用 PyMySQL 和参数化 SQL，不使用 ORM。这样可以直接展示连接建立、事务提交与回滚、SQL 参数绑定和数据库异常处理，同时保持代码规模适合入门项目。

MySQL 在阶段 1 通过单独的 Docker 容器运行。Flask 在 WSL 中运行，并临时提供静态前端文件，使页面和 API 保持同源，不额外引入 CORS 配置或第二个开发服务器。阶段 2 再由 Nginx 提供前端，并为前端和后端编写 Dockerfile，使用 Docker Compose 统一管理三个服务。

## 3. 组件与文件边界

```text
app/
├── frontend/
│   └── src/
│       ├── index.html
│       ├── app.js
│       └── style.css
├── backend/
│   ├── app.py
│   ├── config.py
│   ├── db.py
│   ├── routes.py
│   ├── requirements.txt
│   └── tests/
│       ├── conftest.py
│       ├── test_health.py
│       └── test_items.py
└── database/
    └── init.sql

scripts/
├── start-phase1-mysql.sh
├── stop-phase1-mysql.sh
└── verify-phase1.sh
```

- `app.py`：创建 Flask 应用、注册路由并在阶段 1 提供静态前端。
- `config.py`：从环境变量读取数据库配置，不保存真实密码。
- `db.py`：建立 MySQL 连接并封装查询、事务和连接检查。
- `routes.py`：实现 HTTP 接口、输入校验和统一 JSON 响应。
- `init.sql`：创建数据库和任务表。
- `frontend/src`：提供不依赖构建工具的静态页面。
- `tests`：通过 Flask 测试客户端验证 HTTP 行为，并用测试替身隔离数据库。
- `scripts`：封装可重复执行的 MySQL 启停和阶段验收命令。

## 4. 数据模型

表名为 `ops_tasks`：

| 字段 | 类型 | 约束 | 用途 |
|---|---|---|---|
| `id` | BIGINT UNSIGNED | 主键、自增 | 任务编号 |
| `title` | VARCHAR(120) | 非空 | 任务标题 |
| `description` | TEXT | 非空 | 任务说明 |
| `status` | VARCHAR(20) | 非空、默认 `pending` | 当前状态 |
| `created_at` | TIMESTAMP | 非空、自动生成 | 创建时间 |
| `updated_at` | TIMESTAMP | 非空、自动更新 | 更新时间 |

允许的状态只有 `pending`、`in_progress` 和 `completed`。状态合法性同时由 API 校验和数据库 CHECK 约束保护。

## 5. HTTP 接口

| 方法 | 路径 | 成功响应 | 作用 |
|---|---|---|---|
| GET | `/healthz` | 200 | 返回 Flask 进程存活状态 |
| GET | `/readyz` | 200 或 503 | 检查 MySQL 连接 |
| GET | `/api/items` | 200 | 按创建时间倒序返回任务列表 |
| POST | `/api/items` | 201 | 新增任务 |
| PUT | `/api/items/<id>` | 200 | 修改标题、描述和状态 |
| DELETE | `/api/items/<id>` | 204 | 删除任务 |

POST 请求要求非空的 `title` 和 `description`，`status` 省略时使用 `pending`。PUT 请求要求提交完整的三个业务字段，避免部分更新带来的额外分支。未知字段不影响处理，但不会写入数据库。

所有非 204 响应使用 JSON。错误格式统一为：

```json
{
  "error": {
    "code": "validation_error",
    "message": "title is required"
  }
}
```

## 6. 请求与数据流

1. 浏览器通过 Flask 的 `/` 路径加载静态页面。
2. JavaScript 使用同源相对路径调用 Flask `/api/items`。
3. Flask 校验请求数据。
4. `db.py` 使用 PyMySQL 执行参数化 SQL。
5. 写操作成功后提交事务，失败时回滚。
6. Flask 返回 JSON，页面重新渲染任务列表。

前端不保存数据库密码，也不直接连接 MySQL。数据库配置只通过 Flask 进程的环境变量传入。阶段 1 不启用 CORS；阶段 2 的 Nginx 仍使用相同的 `/api` 路径转发请求，因此前端代码无需改写地址。

## 7. 配置与安全

后端读取以下环境变量：

- `DB_HOST`
- `DB_PORT`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`
- `FLASK_HOST`
- `FLASK_PORT`

`.env.example` 只提供变量名和无敏感示例值；真实本地值存放在被 Git 忽略的 `.env` 中。SQL 必须使用参数绑定，禁止拼接用户输入。数据库异常只记录异常类型和上下文，不把密码、连接字符串或 SQL 内部错误返回给前端。

## 8. 错误处理

- JSON 缺失、字段为空或状态非法：返回 400 和 `validation_error`。
- 任务不存在：返回 404 和 `item_not_found`。
- MySQL 不可用：业务接口返回 503 和 `database_unavailable`。
- `/readyz` 在 MySQL 不可用时返回 503；`/healthz` 仍返回 200。
- 未预期错误：返回 500 和 `internal_error`，不泄露堆栈或凭据。

## 9. 测试与验收

pytest 至少覆盖：

1. `/healthz` 返回 200。
2. `/` 返回静态前端页面。
3. `/readyz` 在数据库可用和不可用时分别返回 200、503。
4. GET 返回任务列表。
5. POST 成功创建任务。
6. POST 缺少字段或状态非法时返回 400。
7. PUT 成功更新任务，目标不存在时返回 404。
8. DELETE 成功返回 204，目标不存在时返回 404。
9. 数据库异常时业务接口返回 503。

阶段验收脚本必须执行：Python 语法检查、pytest、真实 MySQL 连接检查、一次新增、一次查询、一次修改、一次删除，以及 MySQL 停止后的 readiness 失败验证。

## 10. 完成标准

只有满足以下条件，阶段 1 才算完成：

- 所有 pytest 测试通过。
- 浏览器可以完成任务新增、查看、状态修改和删除。
- 真实 MySQL 中可以观察到数据变化。
- MySQL 停止时 `/readyz` 返回 503，恢复后返回 200。
- 仓库中没有真实密码、Token、私钥或 `.env`。
- README 只描述已经实际验证的阶段 1 能力。
- 代码、测试、验收输出和提交记录已推送至 GitHub。
