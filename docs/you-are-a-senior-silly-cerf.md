# План: docker-compose стек для IoT-наблюдаемости (Фаза 1 + NGINX)

## Контекст

В репозитории `iot-observability-platform` лежит ADR-0001 с архитектурой
Fluent Bit → NGINX → Loki → Grafana на S3-совместимом хранилище.
Нужен запускаемый локально `docker-compose`, который реализует
**Фазу 1 + NGINX** из ADR: monolithic Loki, MinIO как S3, NGINX-фронт
для push-пути, один Fluent Bit + log-generator для end-to-end демо,
Grafana с автопровиженингом datasource'а и базового дашборда.

Цель — иметь воспроизводимый dev/demo-стек, который соответствует C4
[c4-container.puml](../../../../f:/project/pytronic/iot-observability-platform/docs/architecture/c4-container.puml)
и подтверждает заявленные ADR гарантии (1–5 с latency, файловый буфер
Fluent Bit, S3-backed Loki, провижининг Grafana).

Kafka и multi-replica Loki сознательно опущены — это Фаза 3 ADR.

## Соответствие C4 → compose-сервисам

| C4-контейнер                  | Compose-сервис    | Образ                        |
|-------------------------------|-------------------|------------------------------|
| Приложения шлюза              | `log-generator`   | `alpine` + sh-цикл           |
| Fluent Bit                    | `fluent-bit`      | `fluent/fluent-bit:3.0`      |
| NGINX L7                      | `nginx`           | `nginx:1.27-alpine`          |
| Loki Distributor/Ingester/Querier (monolithic) | `loki` | `grafana/loki:3.0.0` |
| Объектное хранилище S3        | `minio` + `minio-init` | `minio/minio`, `minio/mc` |
| Grafana + Ruler               | `grafana`         | `grafana/grafana:11.1.0`     |

## Структура файлов для создания

```
iot-observability-platform/
├── compose/
│   ├── docker-compose.yml
│   ├── .env.example                    # admin-пароли, имена бакетов
│   ├── README.md                       # как запустить, какие порты
│   └── config/
│       ├── loki/
│       │   └── loki-config.yaml        # monolithic, S3 (MinIO), filesystem-cache, WAL
│       ├── nginx/
│       │   └── nginx.conf              # upstream loki:3100, /loki/api/v1/push
│       ├── fluent-bit/
│       │   ├── fluent-bit.conf         # tail /var/log/gateway/*.log + filesystem buffer + output loki
│       │   └── parsers.conf            # JSON parser
│       └── grafana/
│           └── provisioning/
│               ├── datasources/
│               │   └── loki.yaml       # url: http://loki:3100
│               └── dashboards/
│                   ├── dashboards.yaml # provider, путь к json
│                   └── iot-overview.json # rate by service, errors, live tail
```

## Ключевые конфигурационные решения

### Loki (`loki-config.yaml`)
- `auth_enabled: false` (локальный dev)
- `target: all` — single-binary режим
- `common.storage.s3` → endpoint `http://minio:9000`, bucket `loki-chunks`,
  `s3forcepathstyle: true`, креды из env.
- `schema_config` — `tsdb` + `v13` (актуальная версия для Loki 3.x).
- `compactor` включён, retention 168h.
- `limits_config.allow_structured_metadata: true`.
- `ingester.wal.enabled: true`, dir `/loki/wal` (volume) — гарантия из ADR.

### NGINX (`nginx.conf`)
- Слушает `:80`, проксирует `/loki/*` → `http://loki:3100`.
- `client_max_body_size 10m`, `proxy_read_timeout 60s`.
- TLS опускаем (это локальный compose); в проде это терминатор.
- Простой `upstream loki { server loki:3100; }` — задел под scale-up.

### Fluent Bit (`fluent-bit.conf`)
- `[SERVICE] storage.path /var/log/flb-storage`,
  `storage.sync normal`, `storage.checksum on` —
  **файловый буфер** (ADR-критическая фича).
- `[INPUT] tail`, `Path /var/log/gateway/*.log`,
  `storage.type filesystem`, `Parser json`, `Tag gateway.*`.
- `[FILTER] modify` — добавляет статичные метки `host`, `service`, `env`.
- `[OUTPUT] loki`, `host nginx`, `port 80`,
  `labels job=fluentbit, host=$host, service=$service`,
  `batch_wait 1s` (попадаем в 1–5 с SLA из ADR), `Retry_Limit no_limits`.

### log-generator
- Один контейнер `alpine`, в цикле `1/sec` пишет JSON-строку
  `{"ts":..., "level":"info|warn|error", "service":"sensor|api|net", "msg":"..."}`
  в `/var/log/gateway/app.log` на shared volume.
- Уровень и сервис рандомизируются, чтобы дашборд показывал ненулевые
  серии.

### Grafana provisioning
- `datasources/loki.yaml` — datasource `Loki`, `url: http://loki:3100`,
  `isDefault: true`.
- `dashboards/iot-overview.json` — 4 панели:
  - Logs panel (live tail): `{job="fluentbit"}`
  - Errors rate: `sum by (service) (rate({job="fluentbit"} |= "error" [5m]))`
  - Volume by service: `sum by (service) (rate({job="fluentbit"}[1m]))`
  - Stat: total streams.

### Volumes & сеть
- Именованные volumes: `minio-data`, `loki-data`, `fluent-bit-buffer`,
  `gateway-logs` (shared между `log-generator` и `fluent-bit`),
  `grafana-data`.
- Сеть по умолчанию (compose-генерируемая).
- Healthchecks на `loki` (`/ready`), `minio` (`/minio/health/live`),
  `nginx` (`/healthz` через nginx stub_status).
- `depends_on` с `condition: service_healthy` в порядке:
  `minio-init` → `loki` → `nginx` → `fluent-bit`, и параллельно `grafana` ждёт `loki`.

## Порты, которые проброшены наружу

| Порт хоста | Сервис   | Назначение                     |
|------------|----------|--------------------------------|
| 3000       | Grafana  | UI (admin / `GF_SECURITY_ADMIN_PASSWORD`) |
| 3100       | Loki     | API (для отладки и тестов)     |
| 8080       | NGINX    | Push API для внешних Fluent Bit |
| 9000       | MinIO    | S3 API                         |
| 9001       | MinIO    | Web-консоль                    |

## Файлы плана (что и где править)

| Файл                                                 | Действие |
|------------------------------------------------------|----------|
| `compose/docker-compose.yml`                         | создать  |
| `compose/.env.example`                               | создать  |
| `compose/README.md`                                  | создать  |
| `compose/config/loki/loki-config.yaml`               | создать  |
| `compose/config/nginx/nginx.conf`                    | создать  |
| `compose/config/fluent-bit/fluent-bit.conf`          | создать  |
| `compose/config/fluent-bit/parsers.conf`             | создать  |
| `compose/config/grafana/provisioning/datasources/loki.yaml` | создать |
| `compose/config/grafana/provisioning/dashboards/dashboards.yaml` | создать |
| `compose/config/grafana/provisioning/dashboards/iot-overview.json` | создать |

Существующие [docs/adr/0001-log-aggregation-architecture.md](../../../../f:/project/pytronic/iot-observability-platform/docs/adr/0001-log-aggregation-architecture.md)
и [docs/architecture/c4-container.puml](../../../../f:/project/pytronic/iot-observability-platform/docs/architecture/c4-container.puml)
не меняются.

## Верификация

Запуск:
```powershell
cd iot-observability-platform/compose
cp .env.example .env
docker compose up -d
```

End-to-end проверки:
1. `curl http://localhost:3100/ready` → `ready`.
2. `curl http://localhost:8080/loki/api/v1/labels` через NGINX → JSON
   с метками `host`, `service`, `job`.
3. Открыть Grafana http://localhost:3000 → Dashboard *IoT Overview* —
   видны логи и графики rate.
4. Открыть MinIO http://localhost:9001 (`admin/<env>`) → bucket
   `loki-chunks` содержит объекты в `fake/` после ~1 минуты работы.
5. Логи доезжают за **≤5 секунд**: записать строку в shared volume
   (`docker compose exec log-generator sh -c 'echo MARKER >> /var/log/gateway/app.log'`)
   и убедиться, что `{job="fluentbit"} |= "MARKER"` в Grafana находит
   её в пределах SLA.

Failure-сценарий (проверка ADR):
- `docker compose stop nginx` → подождать 30 с (Fluent Bit копит на диск)
  → `docker compose start nginx` → backlog уезжает, потерь нет
  (проверить по непрерывности timestamp'ов в Grafana).
- Дисковый буфер растёт в volume `fluent-bit-buffer`:
  `docker compose exec fluent-bit ls -la /var/log/flb-storage`.

Откат: `docker compose down -v` удаляет все данные.
