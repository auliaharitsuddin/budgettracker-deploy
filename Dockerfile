# FinanceFlow (BudgetTracker) — static single-page app served by nginx.
# nginx-unprivileged runs as UID 101 (non-root) and listens on 8080.
FROM nginxinc/nginx-unprivileged:1.31-alpine

# Replace the default server block with ours (SPA fallback + /healthz).
COPY nginx.conf /etc/nginx/conf.d/default.conf

# The app itself. public/ holds exactly what the browser is allowed to fetch.
COPY public/ /usr/share/nginx/html/

EXPOSE 8080

# busybox wget ships with the alpine base, so no extra layer is needed.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O- http://127.0.0.1:8080/healthz || exit 1
