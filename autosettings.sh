#!/usr/bin/env bash
set -Eeuo pipefail

# === Интерактивный установщик базовой конфигурации Ubuntu ===
# Требования: root. Диалоги через whiptail. Каждый шаг — очистка экрана.

require_root() { if [[ $EUID -ne 0 ]]; then echo "Запусти: sudo bash $0"; exit 1; fi; }

install_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail
  fi
}

cls() { clear || true; }
info_box() { whiptail --title "$1" --msgbox "$2" 12 78; }
yesno() { whiptail --title "$1" --yesno "$2" 12 78; }
input_box() {
  local out; out=$(whiptail --title "$1" --inputbox "$2" 12 78 "${3:-}" 3>&1 1>&2 2>&3) || return 1
  printf "%s" "$out"
}
spinner() { # spinner "msg" cmd...
  local msg="$1"; shift; cls; echo -e "\n$msg...\n"
  set +e; "$@" & local pid=$!; local spin='-\|/'; local i=0
  while kill -0 "$pid" 2>/dev/null; do i=$(( (i+1)%4 )); printf "\r[%c] Работаю..." "${spin:$i:1}"; sleep 0.2; done
  wait "$pid"; local rc=$?; set -e; printf "\r"; return $rc
}
backup_file() { [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)"; }

apply_and_restart_sshd_safely() {
  if sshd -t -f /etc/ssh/sshd_config; then
    systemctl restart ssh || systemctl restart sshd || true
  else
    info_box "SSH" "Ошибка в /etc/ssh/sshd_config. Откат."
    if compgen -G "/etc/ssh/sshd_config.bak.*" >/dev/null; then
      cp -f "$(ls -t /etc/ssh/sshd_config.bak.* | head -n1)" /etc/ssh/sshd_config
    fi
  fi
}

# --- Шаг 1: Hostname + TZ Moscow ---
step_hostname_tz() {
  cls
  yesno "Шаг 1/9 — Имя сервера и часовой пояс" "Установить hostname и часовой пояс Europe/Moscow?" || return 0
  local new_hostname; new_hostname=$(input_box "Имя сервера" "Введи hostname (например, prst-srv-01):" "") || return 0
  [[ -z "$new_hostname" ]] && { info_box "Hostname" "Пустое имя — пропуск."; return 0; }

  spinner "Устанавливаю hostname и часовой пояс" bash -c "
    backup_file /etc/hostname
    backup_file /etc/hosts
    hostnamectl set-hostname \"$new_hostname\"
    grep -qE \"127.0.1.1\\s+$new_hostname\" /etc/hosts || echo -e \"127.0.1.1\t$new_hostname\" >> /etc/hosts
    timedatectl set-timezone Europe/Moscow
    timedatectl set-ntp true
  "
  info_box "Готово" "Имя: $new_hostname\nTZ: Europe/Moscow."
}

# --- Шаг 2: SSH порт/ключ/только ключи/root/лимиты ---
step_ssh_hardening() {
  cls
  yesno "Шаг 2/9 — SSH" "Настроить SSH: кастомный порт, вход только по ключам,\nroot по ключам, MaxAuthTries=2, MaxSessions=2?" || return 0

  local ssh_port; ssh_port=$(input_box "Порт SSH" "Введи новый порт (1024–65535):" "2222") || return 0
  if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1024 || ssh_port > 65535 )); then
    info_box "Порт SSH" "Некорректный порт. Пропуск."; return 0
  fi

  local pubkey; pubkey=$(input_box "Публичный SSH-ключ" "Вставь ключ (ssh-ed25519/ssh-rsa...):" "") || return 0
  [[ -z "$pubkey" ]] && { info_box "SSH-ключ" "Ключ не задан. Пропуск."; return 0; }

  spinner "Применяю SSH-настройки" bash -c "
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
    grep -qxF \"$pubkey\" /root/.ssh/authorized_keys || echo \"$pubkey\" >> /root/.ssh/authorized_keys
    backup_file /etc/ssh/sshd_config
    sed -i \
      -e 's/^#\\?Port .*/Port $ssh_port/' \
      -e 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' \
      -e 's/^#\\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' \
      -e 's/^#\\?PubkeyAuthentication .*/PubkeyAuthentication yes/' \
      -e 's/^#\\?PermitRootLogin .*/PermitRootLogin prohibit-password/' \
      -e 's/^#\\?MaxAuthTries .*/MaxAuthTries 2/' \
      -e 's/^#\\?MaxSessions .*/MaxSessions 2/' \
      /etc/ssh/sshd_config || true
    grep -q '^Port ' /etc/ssh/sshd_config || echo 'Port $ssh_port' >> /etc/ssh/sshd_config
    grep -q '^PasswordAuthentication ' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
    grep -q '^ChallengeResponseAuthentication ' /etc/ssh/sshd_config || echo 'ChallengeResponseAuthentication no' >> /etc/ssh/sshd_config
    grep -q '^PubkeyAuthentication ' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
    grep -q '^PermitRootLogin ' /etc/ssh/sshd_config || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
    grep -q '^MaxAuthTries ' /etc/ssh/sshd_config || echo 'MaxAuthTries 2' >> /etc/ssh/sshd_config
    grep -q '^MaxSessions ' /etc/ssh/sshd_config || echo 'MaxSessions 2' >> /etc/ssh/sshd_config
  "
  apply_and_restart_sshd_safely
  info_box "SSH" "Новый порт: $ssh_port\nВход: только ключи; root — по ключу."
}

# --- Шаг 3: Обновление системы ---
step_updates_now() {
  cls
  yesno "Шаг 3/9 — Обновление" "Выполнить apt update && apt -y full-upgrade?" || return 0
  spinner "Обновляю систему" bash -c "apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade"
  info_box "Готово" "Система обновлена."
}

# --- Шаг 4: Базовые компоненты + Docker/compose ---
step_components() {
  cls
  yesno "Шаг 4/9 — Компоненты" "Установить базовые утилиты и Docker + compose-plugin?" || return 0

  spinner "Ставлю базовые пакеты" bash -c "
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ca-certificates curl gnupg lsb-release git htop wget unzip jq \
      software-properties-common apt-transport-https
  "
  spinner "Устанавливаю Docker" bash -c "
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
  "
  spinner "Устанавливаю docker compose plugin" bash -c "
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || true
  "
  info_box "Готово" "Базовые утилиты и Docker установлены."
}

# --- Шаг 5: Автообновления (unattended-upgrades) ---
step_unattended() {
  cls
  yesno "Шаг 5/9 — Автообновления" "Включить unattended-upgrades (безопасность и система)?" || return 0
  spinner "Настраиваю unattended-upgrades" bash -c "
    DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
    dpkg-reconfigure -fnoninteractive unattended-upgrades
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'CFG'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CFG
    systemctl restart unattended-upgrades || true
  "
  info_box "Готово" "Автообновления включены."
}

# --- Шаг 6: journald (лимиты + 4 месяца) ---
step_journald_limits() {
  cls
  yesno "Шаг 6/9 — Логи journald" "Ограничить размер журналов и хранить не более 4 месяцев?" || return 0
  local max_use; max_use=$(input_box "Лимит journald" "SystemMaxUse (например, 500M или 1G):" "500M") || return 0

  spinner "Настраиваю journald" bash -c "
    backup_file /etc/systemd/journald.conf
    awk '
      BEGIN{f1=0;f2=0}
      /^#?SystemMaxUse=/ {print \"SystemMaxUse=$max_use\"; f1=1; next}
      /^#?SystemMaxFileSize=/ {print \"SystemMaxFileSize=50M\"; f2=1; next}
      {print}
      END{
        if(f1==0) print \"SystemMaxUse=$max_use\";
        if(f2==0) print \"SystemMaxFileSize=50M\";
      }
    ' /etc/systemd/journald.conf > /etc/systemd/journald.conf.new
    mv /etc/systemd/journald.conf.new /etc/systemd/journald.conf
    systemctl restart systemd-journald
    echo 'PATH=/usr/sbin:/usr/bin:/sbin:/bin
0 3 * * 0 root /usr/bin/journalctl --vacuum-time=120d >/dev/null 2>&1' > /etc/cron.d/journald_vacuum_120d
  "
  info_box "Готово" "Лимит: $max_use; хранение: 120 дней."
}

# --- Шаг 7: Кастомный MOTD (автоответ y) ---
step_motd_custom() {
  cls
  yesno "Шаг 7/9 — MOTD" "Отключить стандартный MOTD и поставить кастомный?" || return 0

  spinner "Отключаю стандартный MOTD" bash -c "
    if [[ -d /etc/update-motd.d ]]; then
      backup_file /etc/update-motd.d
      chmod -x /etc/update-motd.d/* || true
    fi
    : > /etc/motd
  "
  spinner "Устанавливаю кастомный MOTD" bash -c "
    yes | bash <(wget -qO- https://dignezzz.github.io/server/dashboard.sh)
  "
  info_box "Готово" "Кастомный MOTD установлен."
}

# --- Шаг 8: sysctl_opt.sh и unlimit_server.sh ---
step_sysctl_unlimit() {
  cls
  yesno "Шаг 8/9 — Оптимизации системы" "Запустить sysctl_opt.sh и unlimit_server.sh (рекомендуется)?" || return 0
  spinner "Применяю sysctl_opt.sh" bash -c "bash <(wget -qO- https://dignezzz.github.io/server/sysctl_opt.sh)"
  spinner "Применяю unlimit_server.sh" bash -c "bash <(wget -qO- https://dignezzz.github.io/server/unlimit_server.sh)"
  info_box "Готово" "Оптимизации применены."
}

# --- Шаг 9: Установка BBR3 и завершение мастера ---
step_bbr3_install_and_exit() {
  cls
  yesno "Шаг 9/9 — Установить BBR3" "Запустить установку BBR3 сейчас? После установки скрипт завершится,\nа установщик BBR предложит перезагрузку." || return 0

  cls
  echo -e "\nЗапускаю установщик BBR3. После его завершения мастер выйдет.\nЕсли установщик попросит перезагрузку — соглашаемся.\n"
  # Реальный запуск установщика BBR3
  bash <(curl -s https://raw.githubusercontent.com/opiran-club/VPS-Optimizer/main/bbrv3.sh --ipv4) || true

  echo -e "\nМастер завершён. Продолжай по инструкциям установщика BBR (перезагрузка).\n"
  exit 0
}

main() {
  require_root
  install_whiptail
  info_box "Мастер настройки" "Интерактивный мастер. После каждого шага — очистка экрана."

  step_hostname_tz;        cls
  step_ssh_hardening;      cls
  step_updates_now;        cls
  step_components;         cls
  step_unattended;         cls
  step_journald_limits;    cls
  step_motd_custom;        cls
  step_sysctl_unlimit;     cls
  step_bbr3_install_and_exit
  # до сюда не дойдём, т.к. шаг BBR завершает мастер
}

main "$@"
