#!/usr/bin/env bash
# Port-forwards Argo CD, Kargo, Grafana and Prometheus. Ctrl-C stops all.
set -euo pipefail

forward() {
  local ns=$1 svc=$2 ports=$3
  # Restart the forward if it drops (e.g. the pod restarts).
  while true; do
    kubectl -n "$ns" port-forward "svc/$svc" "$ports" >/dev/null 2>&1 || true
    sleep 1
  done
}

trap 'kill $(jobs -p) 2>/dev/null' EXIT

forward argocd     argocd-server         8080:443  &
forward kargo      kargo-api             8081:80   &
forward monitoring grafana               3000:80   &
forward monitoring monitoring-prometheus 9090:9090 &

cat <<EOF
Argo CD:    https://localhost:8080  (no login)
Kargo:      http://localhost:8081   (admin / password)
Grafana:    http://localhost:3000   (admin / admin)
Prometheus: http://localhost:9090
EOF

wait
