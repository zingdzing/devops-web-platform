# Deployment boundary

部署内容按验证顺序逐步加入：

1. `compose/`：本地前端、后端和 MySQL 联调。
2. `helm/`：Kubernetes Deployment、StatefulSet、Service、Ingress、PVC、ConfigMap 和 Secret 模板。
3. `monitoring/`：kube-prometheus-stack values、PrometheusRule 和 Grafana Dashboard。

当前阶段只定义边界，不提交未经验证的部署清单。
