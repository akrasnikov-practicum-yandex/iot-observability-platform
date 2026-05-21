# Deploy на VPS

## Требования к серверу

- Ubuntu 22.04 / Debian 12 (или совместимый)
- Docker 24+ и Docker Compose plugin
- Открытые порты: 80, 81, 443, 3000, 3100, 8080, 9000, 9001, 2020

## 1. Подключение к серверу

```bash
ssh root@<VPS_IP>
```

## 2. Установка Docker (если не установлен)

```bash
curl -fsSL https://get.docker.com | sh
docker --version
docker compose version
```

## 3. Клонирование репозитория

```bash
git clone <REPO_URL> /opt/iot-observability
cd /opt/iot-observability/compose
```

## 4. Настройка окружения

```bash
cp .env.example .env
nano .env
```

Обязательно смените все пароли по умолчанию:

```env
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=<strong-password>

GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=<strong-password>

NPM_ADMIN_EMAIL=admin@example.com
NPM_ADMIN_PASSWORD=<strong-password>
```

## 5. Запуск стека

```bash
docker compose up -d
```

Порядок старта: `minio` → `minio-init` → `loki` → `nginx` → `fluent-bit` + `grafana` + `nginx-proxy-manager` → `npm-init`.
Полная готовность — около 60–90 секунд.

```bash
# Следить за статусом
docker compose ps
docker compose logs -f npm-init
```

## 6. Верификация

```bash
# Loki готов?
curl http://<VPS_IP>:3100/ready

# NGINX проксирует?
curl http://<VPS_IP>:8080/loki/api/v1/labels

# NPM зарегистрировал хосты?
curl -s -X POST http://<VPS_IP>:81/api/tokens \
  -H "Content-Type: application/json" \
  -d '{"identity":"admin@example.com","secret":"<NPM_PASSWORD>"}' \
  | grep -o '"token":"[^"]*"'
```

Открыть в браузере:

| Сервис | URL |
|---|---|
| Grafana | `http://<VPS_IP>:3000` |
| NPM Admin | `http://<VPS_IP>:81` |
| MinIO Console | `http://<VPS_IP>:9001` |

## 7. Настройка файрвола (ufw)

```bash
ufw allow 22/tcp      # SSH
ufw allow 80/tcp      # HTTP
ufw allow 443/tcp     # HTTPS
ufw allow 81/tcp      # NPM admin
ufw allow 3000/tcp    # Grafana
ufw allow 8080/tcp    # Fluent Bit push endpoint
ufw allow 9000/tcp    # MinIO S3 API
ufw allow 9001/tcp    # MinIO Console
ufw --force enable
ufw status
```

> Порты 3100 (Loki) и 2020 (Fluent Bit metrics) оставьте закрытыми снаружи —
> доступ только внутри Docker-сети.

## 8. Подключение IoT-шлюза к VPS

На каждом шлюзе в `fluent-bit.conf`:

```ini
[OUTPUT]
    Name    loki
    Match   *
    Host    <VPS_IP>
    Port    8080
    Labels  job=fluentbit, host=${HOSTNAME}, env=prod
```

## 9. Обновление стека

```bash
cd /opt/iot-observability/compose
git pull
docker compose pull
docker compose up -d
```

## 10. Остановка и очистка

```bash
docker compose down        # остановить, сохранить данные
docker compose down -v     # остановить и удалить все volumes
```

## Устранение неполадок

```bash
# Логи конкретного сервиса
docker compose logs -f loki
docker compose logs -f fluent-bit

# Перезапуск одного сервиса
docker compose restart grafana

# Статус healthcheck-ов
docker inspect --format='{{json .State.Health}}' $(docker compose ps -q loki) | jq
```
