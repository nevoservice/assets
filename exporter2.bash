#!/usr/bin/env bash
# =============================================================================
# Скрипт для поднятия node_exporter + xray_exporter + prometheus через systemd
# Prometheus доступен только с одного указанного IP через UFW (порт 9898) (1.1 version)
# =============================================================================

set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│   Мониторинг: node_exporter + xray_exporter + prometheus   │${NC}"
echo -e "${GREEN}│     Prometheus → порт 9898 (только 1 IP)  (Systemd)        │${NC}"
echo -e "${GREEN}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

# ─── 1. Создаём пользователей (если не существуют) ───────────────────────────
echo -e "${YELLOW}Создаём системных пользователей...${NC}"

sudo useradd --system --shell /usr/sbin/nologin --no-create-home prometheus 2>/dev/null || true
sudo useradd --system --shell /usr/sbin/nologin --no-create-home node_exporter 2>/dev/null || true
sudo useradd --system --shell /usr/sbin/nologin --no-create-home xray_exporter 2>/dev/null || true

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
    echo -e "${YELLOW}UFW не активен → включаем (разрешаем SSH)${NC}"
    sudo ufw allow OpenSSH || sudo ufw allow 22/tcp
    sudo ufw --force enable
fi

# Удаляем старые правила для 9898
sudo ufw delete allow 9898 >/dev/null 2>&1 || true
sudo ufw delete allow from any to any port 9898 >/dev/null 2>&1 || true

# Новое правило — только один IP
sudo ufw allow from "$ALLOWED_IP" to any port 9898 proto tcp comment "Prometheus (ограничен по IP)"
sudo ufw reload

echo -e "${GREEN}UFW настроен:${NC}"
sudo ufw status | grep 9898 || echo "Правило не отображается — проверьте вручную"

# ─── 4. Скачиваем и устанавливаем бинарники ──────────────────────────────────
PROM_VERSION="3.0.0"                  # актуальная стабильная на 2026
NODE_VERSION="1.10.2"
ARCH="amd64"                          # arm64 / armv7 и т.д. — измени здесь
OS="linux"

echo -e "${YELLOW}Скачиваем Prometheus v${PROM_VERSION}...${NC}"
wget -q --show-progress "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.${OS}-${ARCH}.tar.gz"
tar xzf "prometheus-${PROM_VERSION}.${OS}-${ARCH}.tar.gz"
sudo mv "prometheus-${PROM_VERSION}.${OS}-${ARCH}/prometheus"     /usr/local/bin/
sudo mv "prometheus-${PROM_VERSION}.${OS}-${ARCH}/promtool"       /usr/local/bin/
rm -rf "prometheus-${PROM_VERSION}."*
[ ! -f /usr/local/bin/prometheus ] && { echo -e "${RED}Ошибка: prometheus не скачался${NC}"; exit 1; }

echo -e "${YELLOW}Скачиваем Node Exporter v${NODE_VERSION}...${NC}"
wget -q --show-progress "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/node_exporter-${NODE_VERSION}.${OS}-${ARCH}.tar.gz"
tar xzf "node_exporter-${NODE_VERSION}.${OS}-${ARCH}.tar.gz"
sudo mv "node_exporter-${NODE_VERSION}.${OS}-${ARCH}/node_exporter" /usr/local/bin/
rm -rf "node_exporter-${NODE_VERSION}."*
[ ! -f /usr/local/bin/node_exporter ] && { echo -e "${RED}Ошибка: node_exporter не скачался${NC}"; exit 1; }

# xray-exporter из актуального репозитория (compassvpn fork, релиз 0.2.0 2026)
echo -e "${YELLOW}Скачиваем xray-exporter (latest from compassvpn/xray-exporter)...${NC}"
wget -q --show-progress "https://github.com/compassvpn/xray-exporter/releases/download/v0.2.0/xray-exporter-${OS}-${ARCH}" -O /usr/local/bin/xray-exporter
chmod +x /usr/local/bin/xray-exporter
[ ! -f /usr/local/bin/xray-exporter ] && { echo -e "${RED}Ошибка: xray-exporter не скачался (проверьте интернет или репозиторий)${NC}"; exit 1; }

# Права
sudo chown root:root /usr/local/bin/prometheus /usr/local/bin/promtool /usr/local/bin/node_exporter /usr/local/bin/xray-exporter
sudo chmod 755 /usr/local/bin/prometheus /usr/local/bin/promtool /usr/local/bin/node_exporter /usr/local/bin/xray-exporter

# ─── 5. Директории и конфиги ─────────────────────────────────────────────────
sudo mkdir -p /etc/prometheus /var/lib/prometheus
sudo chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

# prometheus.yml
cat > /tmp/prometheus.yml << EOF
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

sudo mv /tmp/prometheus.yml /etc/prometheus/prometheus.yml
sudo chown prometheus:prometheus /etc/prometheus/prometheus.yml

# ─── 6. systemd юниты ────────────────────────────────────────────────────────

cat > /etc/systemd/system/node-exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=:9100 \
  --path.procfs=/proc \
  --path.sysfs=/sys \
  --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/xray-exporter.service << 'EOF'
[Unit]
Description=Xray Prometheus Exporter
After=network-online.target

[Service]
User=xray_exporter
Group=xray_exporter
Type=simple
ExecStart=/usr/local/bin/xray-exporter \
  --xray-endpoint=127.0.0.1:54321   # ← ИЗМЕНИТЕ НА РЕАЛЬНЫЙ АДРЕС API Xray (обычно 127.0.0.1:54321 или unix socket)
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus Server
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --web.listen-address=:9898 \
  --web.enable-lifecycle

Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# ─── 7. Запуск и автозагрузка ────────────────────────────────────────────────
sudo systemctl daemon-reload

sudo systemctl enable --now node-exporter
sudo systemctl enable --now xray-exporter
sudo systemctl enable --now prometheus

echo ""
echo -e "${GREEN}┌───────────────────── Готово ─────────────────────┐${NC}"
echo -e "${GREEN}│ Prometheus    → http://<ваш_IP>:9898            │${NC}"
echo -e "${GREEN}│ Доступ ТОЛЬКО с: $ALLOWED_IP                    │${NC}"
echo -e "${GREEN}│ Node Exporter → http://localhost:9100/metrics   │${NC}"
echo -e "${GREEN}│ Xray Exporter → http://localhost:9400/metrics   │${NC}"
echo -e "${GREEN}└─────────────────────────────────────────────────┘${NC}"
echo ""

echo -e "Важно: отредактируйте ${YELLOW}/etc/systemd/system/xray-exporter.service${NC}"
echo -e "       параметр --v2ray-endpoint=... (обычно 127.0.0.1:54321 для Xray API)"
echo -e "       После правки: ${YELLOW}sudo systemctl daemon-reload && sudo systemctl restart xray-exporter${NC}"
echo ""
echo -e "Статус сервисов (проверьте!):"
echo -e "  ${YELLOW}sudo systemctl status node-exporter${NC}"
echo -e "  ${YELLOW}sudo systemctl status xray-exporter${NC}"
echo -e "  ${YELLOW}sudo systemctl status prometheus${NC}"
echo ""
echo -e "Логи: ${YELLOW}journalctl -u xray-exporter -f${NC}   (и аналогично для остальных)"
