# Application

Phase 1 包含三个应用边界：

- `frontend/src/`：由 Flask 临时提供的原生 HTML、CSS 和 JavaScript 页面。
- `backend/`：Flask CRUD API、健康检查、PyMySQL 数据访问和 pytest。
- `database/`：MySQL `ops_tasks` 表初始化 SQL。

运行路径为：浏览器 → Flask `/api/items` → PyMySQL 参数化 SQL → MySQL 8.4。

Phase 2 会为前端和后端分别增加 Dockerfile，并由 Nginx 提供静态页面；API 路径保持 `/api` 不变。
