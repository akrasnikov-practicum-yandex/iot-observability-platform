# IoT Observability Platform

Платформа централизованного наблюдения за парком IoT-шлюзов: сбор, агрегация, хранение и визуализация логов с ~1000 Linux-устройств на ARM с нестабильным сетевым соединением.

## Архитектура

```
[IoT Gateway ×1000]
  └─ Fluent Bit (edge agent)
       └─► NGINX (L7 proxy / TLS termination)
               └─► Loki (log aggregation)
                     └─► MinIO S3 (object storage)
                               ↑
                           Grafana (dashboards + alerting)
```

Полное обоснование выбора стека — в [ADR-0001](docs/adr/0001-log-aggregation-architecture.md).

## Стек

| Компонент     | Технология              | Роль                                         |
|---------------|-------------------------|----------------------------------------------|
| Edge-агент    | Fluent Bit 3.0          | Tail, parse, буферизация, push в Loki        |
| Прокси        | NGINX 1.27              | L7-балансировка, терминация TLS              |
| Хранилище логов | Grafana Loki 3.0.0    | Label-индексация, чанки в S3                 |
| Объектное хранилище | MinIO             | S3-совместимый бэкенд для Loki               |
| Визуализация  | Grafana 11.1.0          | Дашборды, LogQL, Unified Alerting            |

## Быстрый старт

```powershell
cd compose
cp .env.example .env      # при необходимости смените пароли
docker compose up -d
```

Стек стартует за ~60 секунд. Порядок запуска: `minio` → `minio-init` → `loki` → `nginx` → `fluent-bit` + `grafana`.

## Сервисы и порты

| Сервис        | Порт  | Описание                              |
|---------------|-------|---------------------------------------|
| Grafana       | 3000  | UI дашбордов (анонимный доступ включён) |
| Loki          | 3100  | API (для отладки)                     |
| NGINX         | 8080  | Push API для внешних Fluent Bit       |
| MinIO S3      | 9000  | S3 API                                |
| MinIO Console | 9001  | Веб-консоль MinIO                     |
| Fluent Bit    | 2020  | Metrics / health endpoint             |

Учётные данные по умолчанию: Grafana — `admin` / значение `GRAFANA_ADMIN_PASSWORD` из `.env`; MinIO — `admin` / `changeme123`.

## Верификация end-to-end

```powershell
# Loki готов?
curl http://localhost:3100/ready

# NGINX проксирует labels API?
curl http://localhost:8080/loki/api/v1/labels

# Grafana → папка "IoT" → дашборд "IoT Overview"
# http://localhost:3000

# Bucket loki-chunks содержит объекты (через ~1 мин)?
# http://localhost:9001

# Инжект маркерного лога и поиск в Grafana → Explore
docker compose exec log-generator sh -c `
  'echo "{\"ts\":\"$(date -Iseconds)\",\"level\":\"info\",\"service\":\"sensor\",\"msg\":\"MARKER\",\"seq\":0}" >> /var/log/gateway/app.log'
# Запрос: {job="fluentbit"} |= "MARKER"
```

## Проверка отказоустойчивости

```powershell
# Fluent Bit накапливает логи на диске при недоступном NGINX
docker compose stop nginx
Start-Sleep 30

# Буфер должен расти
docker compose exec fluent-bit ls -lh /var/log/flb-storage

# При восстановлении — backlog уезжает без потерь
docker compose start nginx
```

## Подключение реального IoT-шлюза

Настройте Fluent Bit на шлюзе:

```ini
[OUTPUT]
    Name    loki
    Match   *
    Host    <IP-хоста-с-compose>
    Port    8080
    Labels  job=fluentbit, host=${HOSTNAME}, env=prod
```

## Структура репозитория

```
compose/
  config/           # Конфиги сервисов (Fluent Bit, Loki, NGINX, Grafana)
  scripts/          # Генератор логов (симуляция ~1000 устройств)
  docker-compose.yml
  .env.example
docs/
  adr/              # Архитектурные решения (ADR)
```

## Масштабирование

- **Фаза 1** (≤ 1000 устройств, ≤ 10k EPS) — текущая: monolithic Loki + MinIO + NGINX.
- **Фаза 2** — split-режим Loki: distributor / ingester / querier за NGINX, RF=3.
- **Фаза 3** — добавление Kafka между Fluent Bit и Loki для поглощения всплесков и изоляции push-пути от доступности Loki.

## Остановка и очистка

```powershell
docker compose down       # остановить, сохранить данные
docker compose down -v    # остановить и удалить все volumes
```
