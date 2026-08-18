FROM nginxinc/nginx-unprivileged:1.28.1-alpine

COPY --chown=101:101 nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=101:101 src/ /usr/share/nginx/html/

USER 101:101
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=6 \
  CMD ["wget", "--quiet", "--tries=1", "--spider", "http://127.0.0.1:8080/"]
