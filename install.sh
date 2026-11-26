#!/usr/bin/env bash

set -Eeuo pipefail

PANEL_VERSION="3.4.11"
NODE_VERSION="3.4.6"

STATE="${STATE:-/root/remnawave-vpn.env}"
SUMMARY="${SUMMARY:-/root/remnawave-vpn.txt}"
RW_DIR="${RW_DIR:-/opt/remnawave}"
NODE_DIR="${NODE_DIR:-/opt/remnanode}"
NET="${NET:-remnawave-network}"
API="${API:-http://127.0.0.1:3000/api}"
COMPOSE_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml"
ENV_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mСТОП: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'printf "\n\033[1;31mСТОП: упало на строке %s. Поправьте и запустите скрипт ещё раз\033[0m\n" "$LINENO" >&2' ERR

# shellcheck source=/dev/null
load_state() { if [ -f "$STATE" ]; then . "$STATE"; fi; }

save() {
  touch "$STATE"
  { grep -v "^$1=" "$STATE" || true; printf "%s='%s'\n" "$1" "$2"; } > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  chmod 600 "$STATE"
  printf -v "$1" '%s' "$2"
}

# без этих заголовков панель не отвечает на запросы мимо caddy
api() {
  local args=(-sS -X "$1" -H 'content-type: application/json' -H 'x-forwarded-for: 127.0.0.1'
              -H 'x-forwarded-proto: https' -H 'x-remnawave-client-type: browser')
  if [ -n "${TOKEN:-}" ]; then args+=(-H "authorization: Bearer $TOKEN"); fi
  if [ -n "${3:-}" ]; then args+=(-d "$3"); fi
  RESP=$(curl "${args[@]}" "$API$2") || die "панель не отвечает ($1 $2)"
  if ! jq -e '.response' >/dev/null 2>&1 <<<"$RESP"; then
    die "панель вернула ошибку на $1 $2. $(jq -c '.message // .' <<<"$RESP" 2>/dev/null || echo "$RESP")"
  fi
}

clean_domain() {
  local d
  d=$(printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  d=${d#https://}; d=${d#http://}; d=${d%%/*}
  printf '%s' "$d"
}

ask_domains() {
  if [ -z "${PANEL_DOMAIN:-}" ]; then
    read -rp "Домен панели, например adm-k3x9.example.com > " PANEL_DOMAIN </dev/tty
  fi
  if [ -z "${NODE_DOMAIN:-}" ]; then
    read -rp "Домен ноды, например n1.example.com > " NODE_DOMAIN </dev/tty
  fi
  PANEL_DOMAIN=$(clean_domain "$PANEL_DOMAIN")
  NODE_DOMAIN=$(clean_domain "$NODE_DOMAIN")
  local re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  [[ $PANEL_DOMAIN =~ $re ]] || die "домен панели указан неверно (${PANEL_DOMAIN:-пусто})"
  [[ $NODE_DOMAIN =~ $re ]] || die "домен ноды указан неверно (${NODE_DOMAIN:-пусто})"
  [ "$PANEL_DOMAIN" != "$NODE_DOMAIN" ] || die "у панели и ноды должны быть разные домены"
  case "$PANEL_DOMAIN $NODE_DOMAIN" in *example.com*) die "впишите свои домены вместо example.com";; esac
  save PANEL_DOMAIN "$PANEL_DOMAIN"
  save NODE_DOMAIN "$NODE_DOMAIN"
}

check_dns() {
  say "Проверяю, что домены смотрят на этот сервер"
  local d ip
  for d in "$PANEL_DOMAIN" "$NODE_DOMAIN"; do
    ip=$(getent ahostsv4 "$d" | awk 'NR==1{print $1}') || true
    if [ -z "$ip" ] || ! hostname -I | grep -qw "$ip"; then
      die "$d пока не указывает на этот сервер (сейчас ${ip:-записи нет}). Проверьте A-запись и запустите скрипт минут через 10"
    fi
  done
}

install_base() {
  say "Обновляю систему и ставлю Docker, это 5-10 минут"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get update -q
  apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  apt-get -y -q install curl openssl ufw fail2ban jq qrencode

  if [ -s /root/.ssh/authorized_keys ]; then
    cat > /etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
    sshd -t
    systemctl reload ssh
  fi

  cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban

  # чтобы логи докера не съели диск
  mkdir -p /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    echo '{"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"3"}}' > /etc/docker/daemon.json
  fi
  if ! command -v docker >/dev/null; then curl -fsSL https://get.docker.com | sh; fi

  # bbr заметно помогает на дальних маршрутах
  echo tcp_bbr > /etc/modules-load.d/bbr.conf
  modprobe tcp_bbr || true
  cat > /etc/sysctl.d/99-zz-vpn.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 16384 67108864
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
EOF
  sysctl --system >/dev/null
  # reality не любит, когда часы на сервере врут
  timedatectl set-ntp true >/dev/null 2>&1 || true
}

install_panel() {
  say "Ставлю панель Remnawave $PANEL_VERSION и Caddy"
  mkdir -p "$RW_DIR/caddy"
  cd "$RW_DIR"
  curl -fsSL -o docker-compose.yml "$COMPOSE_URL"
  sed -i "s|image: remnawave/backend:.*|image: remnawave/backend:$PANEL_VERSION|" docker-compose.yml

  # .env только при первом запуске, база уже создана со старым паролем
  if [ ! -f .env ]; then
    curl -fsSL -o .env "$ENV_URL"
    local pw
    pw=$(openssl rand -hex 24)
    sed -i "s/^APP_SECRET=.*/APP_SECRET=$(openssl rand -hex 64)/" .env
    sed -i "s/^METRICS_PASS=.*/METRICS_PASS=$(openssl rand -hex 64)/" .env
    sed -i "s/^WEBHOOK_SECRET_HEADER=.*/WEBHOOK_SECRET_HEADER=$(openssl rand -hex 32)/" .env
    sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$pw/" .env
    sed -i "s|^\(DATABASE_URL=\"postgresql://postgres:\)[^\@]*\(@.*\)|\1$pw\2|" .env
  fi
  sed -i "s|^PANEL_DOMAIN=.*|PANEL_DOMAIN=$PANEL_DOMAIN|; s|^FRONT_END_DOMAIN=.*|FRONT_END_DOMAIN=$PANEL_DOMAIN|; s|^SUB_PUBLIC_DOMAIN=.*|SUB_PUBLIC_DOMAIN=$PANEL_DOMAIN/api/sub|" .env

  # 443 занимает нода, обычных посетителей она отправляет сюда на 8443
  cat > caddy/Caddyfile <<EOF
https://$PANEL_DOMAIN {
    encode
    reverse_proxy * http://remnawave:3000
}
https://$NODE_DOMAIN {
    header Content-Type "text/html; charset=utf-8"
    respond "<html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>" 200
}
:443 {
    tls internal
    respond 204
}
EOF
  cat > caddy/docker-compose.yml <<'EOF'
services:
  caddy:
    image: caddy:2.9
    container_name: caddy
    hostname: caddy
    restart: always
    ports:
      - '127.0.0.1:8443:443'
      - '0.0.0.0:80:80'
    networks:
      - remnawave-network
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy-ssl-data:/data
networks:
  remnawave-network:
    name: remnawave-network
    external: true
volumes:
  caddy-ssl-data:
    name: caddy-ssl-data
EOF

  docker compose up -d
  (cd caddy && docker compose up -d --force-recreate)
}

wait_panel() {
  say "Жду, пока панель запустится"
  for _ in $(seq 1 60); do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' remnawave 2>/dev/null)" = healthy ]; then return; fi
    sleep 5
  done
  die "панель не поднялась за 5 минут, смотрите логи (cd $RW_DIR && docker compose logs --tail=50)"
}

setup_firewall() {
  say "Настраиваю фаервол"
  local subnet ssh_port
  # 2222 нужен только панели из докер-сети
  subnet=$(docker network inspect "$NET" -f '{{(index .IPAM.Config 0).Subnet}}')
  # вдруг ssh у хостера не на 22
  ssh_port=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}') || true
  ufw allow "${ssh_port:-22}"/tcp >/dev/null
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw allow 8444/tcp >/dev/null
  ufw allow from "$subnet" to any port 2222 proto tcp >/dev/null
  ufw --force enable >/dev/null
}

panel_login() {
  TOKEN=""
  api GET /auth/status
  if [ "$(jq -r '.response.isRegisterAllowed' <<<"$RESP")" = true ]; then
    say "Создаю администратора панели"
    [ -n "${ADMIN_USER:-}" ] || save ADMIN_USER "admin"
    # панель требует пароль от 24 символов
    [ -n "${ADMIN_PASS:-}" ] || save ADMIN_PASS "Vpn$(openssl rand -hex 14)X9"
    api POST /auth/register "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')"
  else
    [ -n "${ADMIN_PASS:-}" ] || die "в панели уже есть администратор, а пароля от него в $STATE нет"
    api POST /auth/login "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASS" '{username:$u,password:$p}')"
  fi
  TOKEN=$(jq -r '.response.accessToken' <<<"$RESP")
}

create_profile() {
  if [ -n "${PROFILE_UUID:-}" ]; then return; fi
  say "Делаю ключи REALITY и профиль ноды"
  local keys priv sid xpath
  keys=$(docker run --rm ghcr.io/xtls/xray-core x25519)
  priv=$(awk -F': ' 'tolower($1) ~ /private/ {print $2}' <<<"$keys")
  [ -n "$priv" ] || die "не получилось сделать ключ REALITY"
  sid=$(openssl rand -hex 8)
  xpath="/$(openssl rand -hex 6)"
  api POST /config-profiles "$(jq -nc --arg dom "$NODE_DOMAIN" --arg priv "$priv" --arg sid "$sid" --arg xp "$xpath" '
    ({show:false, xver:0, target:"127.0.0.1:8443", serverNames:[$dom], privateKey:$priv, shortIds:[$sid]}) as $reality
    | ({enabled:true, routeOnly:true, destOverride:["http","tls","quic"]}) as $sniff
    | {name:"vpn", config:{
        log:{loglevel:"warning"},
        inbounds:[
          {tag:"VLESS_TCP", port:443, listen:"0.0.0.0", protocol:"vless",
           settings:{clients:[], decryption:"none", flow:"xtls-rprx-vision"}, sniffing:$sniff,
           streamSettings:{network:"raw", security:"reality", realitySettings:$reality}},
          {tag:"VLESS_XHTTP", port:8444, listen:"0.0.0.0", protocol:"vless",
           settings:{clients:[], decryption:"none"}, sniffing:$sniff,
           streamSettings:{network:"xhttp", xhttpSettings:{host:$dom, path:$xp, mode:"stream-one"},
                           security:"reality", realitySettings:$reality}}],
        outbounds:[{tag:"DIRECT", protocol:"freedom"}, {tag:"BLOCK", protocol:"blackhole"}],
        routing:{rules:[
          {ip:["geoip:private"], outboundTag:"BLOCK"},
          {domain:["geosite:private"], outboundTag:"BLOCK"},
          {protocol:["bittorrent"], outboundTag:"BLOCK"},
          {network:"tcp", port:"25,465,587", outboundTag:"BLOCK"}]}}}')"
  save IN_TCP "$(jq -r '.response.inbounds[] | select(.tag=="VLESS_TCP") | .uuid' <<<"$RESP")"
  save IN_XH "$(jq -r '.response.inbounds[] | select(.tag=="VLESS_XHTTP") | .uuid' <<<"$RESP")"
  save PROFILE_UUID "$(jq -r '.response.uuid' <<<"$RESP")"
  docker rmi ghcr.io/xtls/xray-core >/dev/null 2>&1 || true
}

create_node() {
  if [ -n "${NODE_UUID:-}" ]; then return; fi
  say "Добавляю ноду в панель"
  local gw
  # нода на этом же сервере, панель ходит к ней через шлюз докер-сети
  gw=$(docker network inspect "$NET" -f '{{(index .IPAM.Config 0).Gateway}}')
  api POST /nodes "$(jq -nc --arg a "$gw" --arg p "$PROFILE_UUID" --arg t "$IN_TCP" --arg x "$IN_XH" \
    '{name:"node-1", address:$a, port:2222, configProfile:{activeConfigProfileUuid:$p, activeInbounds:[$t,$x]}}')"
  save NODE_UUID "$(jq -r '.response.uuid' <<<"$RESP")"
}

start_node() {
  say "Запускаю ноду Remnawave $NODE_VERSION"
  mkdir -p "$NODE_DIR"
  if [ ! -f "$NODE_DIR/docker-compose.yml" ]; then
    local key
    api GET /keygen
    key=$(jq -r '.response.secretKey // .response.payload // .response.pubKey' <<<"$RESP")
    (umask 077; cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:$NODE_VERSION
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      NODE_PORT: "2222"
      SECRET_KEY: "$key"
EOF
    )
  fi
  (cd "$NODE_DIR" && docker compose up -d)
  for _ in $(seq 1 36); do
    api GET "/nodes/$NODE_UUID"
    if [ "$(jq -r '.response.isConnected' <<<"$RESP")" = true ]; then return; fi
    sleep 5
  done
  die "нода не подключилась к панели за 3 минуты, смотрите логи (cd $NODE_DIR && docker compose logs --tail=50)"
}

create_hosts() {
  if [ -n "${HOSTS_DONE:-}" ]; then return; fi
  say "Создаю подключения Основной и Запасной"
  api POST /hosts "$(jq -nc --arg p "$PROFILE_UUID" --arg i "$IN_TCP" --arg a "$NODE_DOMAIN" \
    '{inbound:{configProfileUuid:$p, configProfileInboundUuid:$i}, remark:"Основной", address:$a, port:443, fingerprint:"firefox"}')"
  api POST /hosts "$(jq -nc --arg p "$PROFILE_UUID" --arg i "$IN_XH" --arg a "$NODE_DOMAIN" \
    '{inbound:{configProfileUuid:$p, configProfileInboundUuid:$i}, remark:"Запасной", address:$a, port:8444, fingerprint:"firefox"}')"
  # xmux держит всё в одном соединении, такое тспу морозит реже
  api PATCH /hosts "$(jq -nc --arg u "$(jq -r '.response.uuid' <<<"$RESP")" \
    '{uuid:$u, xhttpExtraParams:{xmux:{maxConnections:1, cMaxReuseTimes:0, hMaxRequestTimes:"600-900", hMaxReusableSecs:"1800-3000", hKeepAlivePeriod:30}}}')"
  save HOSTS_DONE 1
}

setup_squad() {
  api GET /internal-squads
  save SQUAD_UUID "$(jq -r '([.response.internalSquads[] | select(.name=="Default-Squad")][0] // .response.internalSquads[0]).uuid' <<<"$RESP")"
  api PATCH /internal-squads "$(jq -nc --arg u "$SQUAD_UUID" --arg t "$IN_TCP" --arg x "$IN_XH" '{uuid:$u, inbounds:[$t,$x]}')"
}

create_user() {
  [[ $1 =~ ^[A-Za-z0-9_-]{3,36}$ ]] || die "имя пользователя нужно латиницей, от 3 до 36 символов (буквы, цифры, _ и -)"
  local exp
  exp="$(( $(date -u +%Y) + 10 ))-01-01T00:00:00.000Z"
  api POST /users "$(jq -nc --arg n "$1" --arg e "$exp" --arg s "$SQUAD_UUID" '{username:$n, expireAt:$e, activeInternalSquads:[$s]}')"
  SUB=$(jq -r '.response.subscriptionUrl' <<<"$RESP")
}

show_link() {
  printf '\nСсылка подписки для %s\n%s\n\n' "$1" "$2"
  if command -v qrencode >/dev/null; then qrencode -t ansiutf8 -m 1 "$2"; fi
}

do_install() {
  # shellcheck source=/dev/null
  [ -r /etc/os-release ] && . /etc/os-release
  [ "${ID:-}" = ubuntu ] || die "скрипт рассчитан на Ubuntu 24.04"
  load_state
  ask_domains
  check_dns
  install_base
  install_panel
  wait_panel
  setup_firewall
  panel_login
  create_profile
  create_node
  start_node
  create_hosts
  setup_squad
  if [ -z "${MAIN_SUB:-}" ]; then
    create_user myvpn
    save MAIN_SUB "$SUB"
  fi
  {
    echo "Панель https://$PANEL_DOMAIN"
    echo "Логин $ADMIN_USER"
    echo "Пароль $ADMIN_PASS"
    echo "Подписка myvpn $MAIN_SUB"
  } > "$SUMMARY"
  chmod 600 "$SUMMARY"
  do_info
  printf '\n\033[1;32mГОТОВО. Всё это лежит в %s\033[0m\n' "$SUMMARY"
}

do_info() {
  load_state
  [ -n "${MAIN_SUB:-}" ] || die "установка ещё не закончена, сначала запустите bash install.sh"
  printf '\nПанель   https://%s\nЛогин    %s\nПароль   %s\n' "$PANEL_DOMAIN" "$ADMIN_USER" "$ADMIN_PASS"
  show_link "myvpn" "$MAIN_SUB"
}

do_add_user() {
  [ -n "${1:-}" ] || die "укажите имя, например bash install.sh add-user mama"
  load_state
  [ -n "${SQUAD_UUID:-}" ] || die "установка ещё не закончена, сначала запустите bash install.sh"
  panel_login
  create_user "$1"
  echo "Подписка $1 $SUB" >> "$SUMMARY"
  show_link "$1" "$SUB"
  printf '\n\033[1;32mГОТОВО, пользователь %s создан\033[0m\n' "$1"
}

main() {
  [ "$(id -u)" -eq 0 ] || die "запустите скрипт от root"
  case "${1:-install}" in
    install) do_install ;;
    add-user) do_add_user "${2:-}" ;;
    info) do_info ;;
    *) die "не знаю команду $1, есть install, add-user и info" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
