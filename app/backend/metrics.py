import time

from flask import Flask, Response, g, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

BUCKETS = (0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5)


def register_metrics(app: Flask) -> CollectorRegistry:
    registry = CollectorRegistry()
    requests_total = Counter(
        "devops_http_requests_total",
        "Business HTTP requests",
        ("method", "endpoint", "status"),
        registry=registry,
    )
    request_duration = Histogram(
        "devops_http_request_duration_seconds",
        "Business HTTP request duration",
        ("method", "endpoint"),
        buckets=BUCKETS,
        registry=registry,
    )
    app_info = Gauge(
        "devops_app_info",
        "Application build information",
        ("version",),
        registry=registry,
    )
    app_info.labels(version=app.config["APP_VERSION"]).set(1)
    app.extensions["prometheus_registry"] = registry

    def should_observe_request() -> bool:
        return request.path != "/metrics" and request.endpoint != "static"

    @app.before_request
    def start_request_timer():
        if should_observe_request():
            g.prometheus_request_started_at = time.perf_counter()

    @app.after_request
    def observe_request(response):
        started_at = getattr(g, "prometheus_request_started_at", None)
        if started_at is None or not should_observe_request():
            return response

        endpoint = request.url_rule.rule if request.url_rule else "unmatched"
        method = request.method
        requests_total.labels(
            method=method,
            endpoint=endpoint,
            status=str(response.status_code),
        ).inc()
        request_duration.labels(method=method, endpoint=endpoint).observe(
            time.perf_counter() - started_at
        )
        return response

    @app.get("/metrics")
    def metrics():
        return Response(generate_latest(registry), content_type=CONTENT_TYPE_LATEST)

    return registry
