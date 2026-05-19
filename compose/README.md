# IoT Observability — Local Stack (Phase 1 + NGINX)

Local docker-compose реализует **Фазу 1 + NGINX** из
[ADR-0001](../docs/adr/0001-log-aggregation-architecture.md):

```
log-generator → Fluent Bit → NGINX → Loki (monolithic) → S3 (MinIO)
                                                ↑
                                           Grafana
```

## Сервисы и порты

| Сервис        | Порт хоста | Что там                              |
|---------------|------------|--------------------------------------|
| Grafana       | 3000       | UI: admin / `GRAFANA_ADMIN_PASSWORD` |
| Loki          | 3100       | API (прямой доступ для отладки)      |
| NGINX         | 8080       | Push API для внешних Fluent Bit      |
| MinIO S3      | 9000       | S3 API                               |
| MinIO Console | 9001       | Web-консоль                          |
| Fluent Bit    | 2020       | Metrics / health endpoint            |

## Быстрый старт

```powershell
cd compose
cp .env.example .env          # при необходимости смените пароли
docker compose up -d
```

Стек стартует в следующем порядке: `minio` → `minio-init` → `loki` → `nginx`
→ `fluent-bit` + `grafana`. Полная готовность — около 60 секунд.

## Верификация end-to-end

```powershell
# 1. Loki готов?
curl http://localhost:3100/ready

# 2. NGINX проксирует labels API?
curl http://localhost:8080/loki/api/v1/labels

# 3. Grafana — открыть дашборд "IoT Overview" в папке IoT
# http://localhost:3000  (анонимный доступ включён)

# 4. MinIO — bucket loki-chunks содержит объекты после ~1 мин
# http://localhost:9001  (admin / changeme123)

# 5. SLA: проверить latency ≤ 5 с
docker compose exec log-generator sh -c 'echo "{\"ts\":\"$(date -Iseconds)\",\"level\":\"info\",\"service\":\"sensor\",\"msg\":\"MARKER\",\"seq\":0}" >> /var/log/gateway/app.log'
# Затем в Grafana → Explore → {job="fluentbit"} |= "MARKER"
```

## Failure scenario (проверка ADR)

```powershell
# Fluent Bit накапливает логи на диске при недоступном NGINX
docker compose stop nginx
Start-Sleep 30

# Смотрим буфер (должен расти)
docker compose exec fluent-bit ls -lh /var/log/flb-storage

# Восстанавливаем — backlog уезжает без потерь
docker compose start nginx
```

## Добавить внешний Fluent Bit (реальный IoT-шлюз)

Настройте output в Fluent Bit на шлюзе:

```ini
[OUTPUT]
    Name    loki
    Match   *
    Host    <IP-машины-с-compose>
    Port    8080
    Labels  job=fluentbit, host=${HOSTNAME}, env=prod
```

## Остановка и очистка

```powershell
docker compose down        # остановить, сохранить данные
docker compose down -v     # остановить и удалить все volumes
```
