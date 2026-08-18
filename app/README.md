# Application boundary

后续 Phase 1 会在这里增加三个边界清晰的组件：

- `frontend/`：Nginx 托管的 HTML、CSS 和 JavaScript 静态页面。
- `backend/`：Flask CRUD API、健康检查、数据库连接和 Prometheus 指标。
- `database/`：MySQL 表结构和初始化数据。

当前阶段不创建空的 Dockerfile 或应用源码，避免让公开仓库误显得功能已经实现。
