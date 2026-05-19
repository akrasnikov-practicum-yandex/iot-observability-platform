#!/bin/sh
# Simulates an IoT gateway writing structured JSON logs every second.
# Produces 3 services (sensor/api/net) and 3 levels (info/warn/error)
# so Grafana dashboards display non-trivial multi-series charts.

mkdir -p /var/log/gateway
seq=0

while true; do
  mod3=$((seq % 3))
  mod5=$((seq % 5))

  case $mod3 in
    0) svc=sensor ;;
    1) svc=api ;;
    *) svc=net ;;
  esac

  case $mod5 in
    0|1|2) lvl=info ;;
    3) lvl=warn ;;
    *) lvl=error ;;
  esac

  printf '{"ts":"%s","level":"%s","service":"%s","msg":"device reading","seq":%d}\n' \
    "$(date -Iseconds)" "$lvl" "$svc" $seq >> /var/log/gateway/app.log

  seq=$((seq + 1))
  sleep 1
done
