#!/usr/bin/env bash
# =============================================================================
# Скрипт для поднятия node_exporter + xray_exporter + prometheus в Docker
# Prometheus доступен только с одного указанного IP через UFW (порт 9898)
# =============================================================================

set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│   Мониторинг: node_exporter + xray_exporter + prometheus   │${NC}"
echo -e "${GREEN}│               Prometheus → порт 9898 (только 1 IP)          │${NC}"
echo -e "${GREEN}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ─── 1. Проверка и установка Docker ──────────────────────────────────────────
echo -n "Проверка Docker... "

if ! command -v docker &> /dev/null || ! docker compose version &> /dev/null; then
    echo -e "${RED}Docker или docker compose не найден${NC}"
    echo -e "${YELLOW}Устанавливаем Docker официальным способом...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh || {
        echo -e "${RED}Ошибка установки Docker. Выход.${NC}"
        exit 1
    }
    rm -f get-docker.sh

    # Убеждаемся, что compose-plugin установлен (обычно идёт вместе)
    sudo apt-get update -qq >/dev/null
    sudo apt-get install -y docker-compose-plugin >/dev/null || true

    if ! docker compose version &> /dev/null; then
        echo -e "${RED}docker compose всё ещё не работает после установки${NC}"
        exit 1
    fi
    echo -e "${GREEN}Docker + Compose установлены${NC}"
else
    echo -e "${GREEN}OK${NC}"
fi

# Пользователь в группе docker?
if ! groups | grep -q docker; then
    echo -e "${YELLOW}Добавляем пользователя в группу docker...${NC}"
    sudo usermod -aG docker "$USER"
    echo -e "${YELLOW}Перелогиньтесь (logout/login или newgrp docker) и запустите скрипт заново${NC}"
    exit 0
fi

# ─── 2. Запрос IP для доступа к Prometheus ────────────────────────────────
ALLOWED_IP=""
while [[ -z "$ALLOWED_IP" ]]; do
    echo -en "${YELLOW}IP-адрес, которому разрешить доступ к Prometheus (9898): ${NC}"
    read -r ALLOWED_IP

    if [[ ! $ALLOWED_IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo -e "${RED}Некорректный IPv4 адрес. Попробуйте снова.${NC}"
        ALLOWED_IP=""
    fi
done

echo -e "${GREEN}Разрешаем доступ к Prometheus только с: $ALLOWED_IP${NC}"

# ─── 3. Проверка и настройка UFW ─────────────────────────────────────────────
echo -n "Проверка UFW... "

if ! command -v ufw &> /dev/null; then
    echo -e "${YELLOW}UFW не найден → устанавливаем${NC}"
    sudo apt-get update -qq
    sudo apt-get install -y ufw
fi

if ! sudo ufw status | grep -q "Status: active"; then
    echo -e "${YELLOW}UFW не активен → включаем${NC}"
    # Разрешаем SSH (чтобы не потерять доступ к серверу!)
    sudo ufw allow OpenSSH || sudo ufw allow 22/tcp
    sudo ufw --force enable
fi

# Удаляем старые правила для порта 9898 (если были)
sudo ufw delete allow 9898 >/dev/null 2>&1 || true
sudo ufw delete allow from any to any port 9898 >/dev/null 2>&1 || true

# Добавляем правило: только указанный IP → порт 9898
sudo ufw allow from "$ALLOWED_IP" to any port 9898 proto tcp comment "Prometheus (ограничен по IP)"
sudo ufw reload

echo -e "${GREEN}UFW настроен:${NC}"
sudo ufw status | grep 9898 || echo "Правило не отображается (возможно, ошибка — проверьте вручную)"

# ─── 4. Создаём docker-compose.yml ───────────────────────────────────────────
cat > docker-compose.yml << 'EOF'
version: "3.8"

services:
  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: unless-stopped
    network_mode: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'

  xray-exporter:
    image: wi1dcard/v2ray-exporter:master
    container_name: xray-exporter
    restart: unless-stopped
    command:
      - "--v2ray-endpoint=127.0.0.1:54321"   # ← ИЗМЕНИТЕ НА РЕАЛЬНЫЙ АДРЕС API Xray
    ports:
      - "9400:9400"

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    ports:
      - "9898:9090"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/usr/share/prometheus/console_libraries'
      - '--web.console.templates=/usr/share/prometheus/consoles'
      - '--web.enable-lifecycle'

volumes:
  prometheus_data:
EOF

# ─── 5. Базовый prometheus.yml ───────────────────────────────────────────────
cat > prometheus.yml << EOF
global:
  scrape_interval:     15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']

  - job_name: 'xray'
    static_configs:
      - targets: ['localhost:9400']
EOF

# ─── 6. Запуск ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Запускаем стек...${NC}"
docker compose up -d

echo ""
echo -e "${GREEN}┌───────────────────── Готово ─────────────────────┐${NC}"
echo -e "${GREEN}│ Prometheus → http://<ваш_IP>:9898               │${NC}"
echo -e "${GREEN}│ Доступ разрешён ТОЛЬКО с: $ALLOWED_IP           │${NC}"
echo -e "${GREEN}│ Node Exporter → http://localhost:9100/metrics   │${NC}"
echo -e "${GREEN}│ Xray Exporter → http://localhost:9400/metrics   │${NC}"
echo -e "${GREEN}└─────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "Важно: в docker-compose.yml измените ${YELLOW}--v2ray-endpoint${NC} на реальный адрес API Xray"
echo -e "Затем: ${YELLOW}docker compose up -d${NC}"
echo ""
echo -e "Логи:     ${YELLOW}docker compose logs -f${NC}"
echo -e "Остановить:${YELLOW} docker compose down${NC}"
echo -e "Статус UFW:${YELLOW} sudo ufw status${NC}"
