#!/usr/bin/env bash
set -Eeuo pipefail

# === Интерактивный установщик базовой конфигурации Ubuntu ===
# Требования: root. Диалоги через whiptail. Каждый шаг — очистка экрана.

# --- Утилиты ---
require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Запусти скрипт от root: sudo bash $0"
    exit 1
  fi
}

install_whiptail() {
  if ! command -v whiptail >/dev/null 2>&1; then
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail
  fi
}

cls() { clear || true; }

info_box() {
  whiptail --title "$1" --msgbox "$2" 12 78
}

yesno() {
  local title="$1"; shift
  local text="$1"; shift || true
  if whiptail --title "$title" --yesno "$text" 12 78; then return 0; else return 1; fi
}

input_box() {
  local title="$1"; shift
  local text="$1"; shift
  local default="${1:-}"
  local out
  out=$(whiptail --title "$title" --inputbox "$text" 12 78 "$default" 3>&1 1>&2 2>&3) || return 1
  printf "%s" "$out"
}

password_box() {
  local title="$1"; shift
  local text="$1"; shift
  local out
  out=$(whiptail --title "$title" --passwordbox "$text" 12 78 3>&1 1>&2 2>&3) || return 1
  printf "%s" "$out"
}

spinner() {
  # spinner "Описание задачи" command args...
  local msg="$1"; shift
  cls
  echo -e "\n$msg...\n"
  set +e
  "$@" &
  local pid=$!
  local spin='-\|/'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\r[%c] Работаю..." "${spin:$i:1}"
    sleep 0.2
  done
  wait "$pid"
  local rc=$?
  set -e
  printf "\r"
  return $rc
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

apply_and_restart_sshd_safely() {
  # Проверяем синтаксис и перезапускаем ssh
  if sshd -t -f /etc/ssh/sshd_config; then
    systemctl restart ssh || systemctl restart sshd || true
  else
    info_box "SSH" "Обнаружены ошибки в /etc/ssh/sshd_config. Откатываю изменения."
    if compgen -G "/etc/ssh/sshd_config.bak.*" >/dev/null; then
      local last_backup
      last_backup=$(ls -t /etc/ssh/sshd_config.bak.* | head -n1)
      cp -f "$last_backup" /etc/ssh/sshd_config
    fi
  fi
}

# --- Шаг 1: Hostname + TZ Moscow ---
step_hostname_tz() {
  cls
  if ! yesno "Шаг 1/8 — Имя сервера и часовой пояс" "Установить hostname и часовой пояс (Europe/Moscow)?"; then
    return 0
  fi

  local new_hostname
  new_hostname=$(input_box "Имя сервера (hostname)" "Введи имя сервера (например, prst-srv-01):" "") || return 0
  if [[ -z "$new_hostname" ]]; then
    info_box "Hostname" "Пустое имя — шаг пропущен."
    return 0
  fi

  spinner "Устанавливаю hostname и часовой пояс Europe/Moscow" bash -c "
    backup_file /etc/hostname
    backup_file /etc/hosts

    hostnamectl set-hostname \"$new_hostname\"
    # корректируем /etc/hosts
    if ! grep -qE \"127.0.1.1\\s+$new_hostname\" /etc/hosts; then
      echo -e \"127.0.1.1\t$new_hostname\" >> /etc/hosts
    fi

    timedatectl set-timezone Europe/Moscow
    timedatectl set-ntp true
  "

  info_box "Готово" "Имя сервера: $new_hostname\nЧасовой пояс: Europe/Moscow."
}

# --- Шаг 2: SSH: порт, ключ, только по ключам, root, MaxAuthTries/Sessions ---
step_ssh_hardening() {
  cls
  if ! yesno "Шаг 2/8 — SSH-настройки" "Настроить SSH: кастомный порт, вход только по ключам,\nroot по ключам, MaxAuthTries=2, MaxSessions=2?"; then
    return 0
  fi

  local ssh_port
  ssh_port=$(input_box "Порт SSH" "Введи новый порт SSH (1024–65535):" "2222") || return 0
  if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || (( ssh_port < 1024 || ssh_port > 65535 )); then
    info_box "Порт SSH" "Некорректный порт. Шаг пропущен."
    return 0
  fi

  local pubkey
  pubkey=$(input_box "Публичный SSH-ключ" "Вставь публичный ключ (ssh-ed25519/ssh-rsa...):" "") || return 0
  if [[ -z "$pubkey" ]]; then
    info_box "SSH-ключ" "Ключ не задан. Шаг пропущен."
    return 0
  fi

  spinner "Применяю SSH-настройки" bash -c "
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    # Добавим ключ, если его ещё нет
    grep -qxF \"$pubkey\" /root/.ssh/authorized_keys || echo \"$pubkey\" >> /root/.ssh/authorized_keys

    backup_file /etc/ssh/sshd_config

    # Чистим ключевые параметры и задаём желаемые
    sed -i \
      -e 's/^#\\?Port .*/Port $ssh_port/' \
      -e 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' \
      -e 's/^#\\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' \
      -e 's/^#\\?PubkeyAuthentication .*/PubkeyAuthentication yes/' \
      -e 's/^#\\?PermitRootLogin .*/PermitRootLogin prohibit-password/' \
      -e 's/^#\\?MaxAuthTries .*/MaxAuthTries 2/' \
      -e 's/^#\\?MaxSessions .*/MaxSessions 2/' \
      /etc/ssh/sshd_config || true

    # Если строк нет — добавим
    grep -q '^Port ' /etc/ssh/sshd_config || echo 'Port $ssh_port' >> /etc/ssh/sshd_config
    grep -q '^PasswordAuthentication ' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
    grep -q '^ChallengeResponseAuthentication ' /etc/ssh/sshd_config || echo 'ChallengeResponseAuthentication no' >> /etc/ssh/sshd_config
    grep -q '^PubkeyAuthentication ' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
    grep -q '^PermitRootLogin ' /etc/ssh/sshd_config || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
    grep -q '^MaxAuthTries ' /etc/ssh/sshd_config || echo 'MaxAuthTries 2' >> /etc/ssh/sshd_config
    grep -q '^MaxSessions ' /etc/ssh/sshd_config || echo 'MaxSessions 2' >> /etc/ssh/sshd_config
  "

  apply_and_restart_sshd_safely
  info_box "SSH перезапущен" "Новый порт SSH: $ssh_port\nДоп.: вход только по ключам, root разрешён по ключу."
}

# --- Шаг 3: Одноразовое обновление системы сейчас ---
step_updates_now() {
  cls
  if ! yesno "Шаг 3/8 — Обновить систему" "Выполнить обновление пакетов (apt update && apt -y full-upgrade)?"; then
    return 0
  fi
  spinner "Обновляю систему" bash -c "
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
  "
  info_box "Готово" "Система обновлена."
}

# --- Шаг 4: Базовые компоненты + Docker/compose ---
step_components() {
  cls
  if ! yesno "Шаг 4/8 — Компоненты" "Установить базовые утилиты (curl, git, htop и т.п.)\nи Docker + docker compose plugin?"; then
    return 0
  fi

  spinner "Ставлю базовые пакеты" bash -c "
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ca-certificates curl gnupg lsb-release git htop wget unzip jq \
      software-properties-common apt-transport-https
  "

  # Docker через официальный скрипт (как ты делаешь)
  spinner "Устанавливаю Docker" bash -c "
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
  "

  # compose-plugin
  spinner "Устанавливаю docker compose plugin" bash -c "
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin || true
  "

  info_box "Готово" "Установлены базовые утилиты и Docker (+compose plugin)."
}

# --- Шаг 5: Автообновления безопасности (unattended-upgrades) ---
step_unattended() {
  cls
  if ! yesno "Шаг 5/8 — Автообновления" "Включить unattended-upgrades для безопасности и системы?"; then
    return 0
  fi

  spinner "Настраиваю unattended-upgrades" bash -c "
    DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades
    dpkg-reconfigure -fnoninteractive unattended-upgrades

    # Чаще проверять (ежедневно)
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'CFG'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CFG
    systemctl restart unattended-upgrades || true
  "
  info_box "Готово" "Автообновления включены."
}

# --- Шаг 6: journald: лимиты + вакуум старше 4 месяцев ---
step_journald_limits() {
  cls
  if ! yesno "Шаг 6/8 — Логи journald" "Ограничить размер журналов и хранить не более 4 месяцев?"; then
    return 0
  fi

  # Спросим желаемый общий лимит (по-умолчанию 500M)
  local max_use
  max_use=$(input_box "Лимит journald" "SystemMaxUse (например, 500M или 1G):" "500M") || return 0

  spinner "Настраиваю journald и vacuum-политику" bash -c "
    backup_file /etc/systemd/journald.conf
    awk '
      BEGIN{found1=0;found2=0}
      /^#?SystemMaxUse=/ {print \"SystemMaxUse=$max_use\"; found1=1; next}
      /^#?SystemMaxFileSize=/ {print \"SystemMaxFileSize=50M\"; found2=1; next}
      {print}
      END{
        if(found1==0) print \"SystemMaxUse=$max_use\";
        if(found2==0) print \"SystemMaxFileSize=50M\";
      }
    ' /etc/systemd/journald.conf > /etc/systemd/journald.conf.new
    mv /etc/systemd/journald.conf.new /etc/systemd/journald.conf

    systemctl restart systemd-journald

    # Крон: еженедельно удалять журналы старше 120 дней (≈4 мес)
    echo 'PATH=/usr/sbin:/usr/bin:/sbin:/bin
# vacuum older than 120 days weekly
0 3 * * 0 root /usr/bin/journalctl --vacuum-time=120d >/dev/null 2>&1' > /etc/cron.d/journald_vacuum_120d
  "
  info_box "Готово" "journald ограничен до $max_use; старше 120 дней — очищается еженедельно."
}

# --- Шаг 7: Кастомный MOTD (отключить стандартный, включить кастом) ---
step_motd_custom() {
  cls
  if ! yesno "Шаг 7/8 — MOTD" "Отключить стандартный MOTD и поставить кастомный (dashboard.sh)?"; then
    return 0
  fi

  spinner "Отключаю стандартный MOTD" bash -c "
    if [[ -d /etc/update-motd.d ]]; then
      backup_file /etc/update-motd.d
      chmod -x /etc/update-motd.d/* || true
    fi
    # Статический /etc/motd не обязателен, но очистим
    : > /etc/motd
  "

  spinner "Устанавливаю кастомный MOTD (dashboard.sh)" bash -c "
    bash <(wget -qO- https://dignezzz.github.io/server/dashboard.sh)
  "

  info_box "Готово" "Стандартный MOTD отключён, кастомный установлен."
}

# --- Шаг 8: Вывести ссылку/команду на BBR3 (без запуска) ---
step_bbr3_link() {
  cls
  # Просто показать команду (как просил) — без выполнения.
  local cmd='bash <(curl -s https://raw.githubusercontent.com/opiran-club/VPS-Optimizer/main/bbrv3.sh --ipv4)'
  whiptail --title "Шаг 8/8 — BBR3 (инфо)" --msgbox "Для установки BBR3 (не запускаю автоматически):\n\n$cmd\n\nСкопируй эту команду и выполни вручную при необходимости." 14 78
}

# --- Основной поток ---
main() {
  require_root
  install_whiptail

  info_box "Мастер настройки" "Запускаю интерактивный мастер. После каждого шага — очистка экрана."

  step_hostname_tz;  cls
  step_ssh_hardening; cls
  step_updates_now;   cls
  step_components;    cls
  step_unattended;    cls
  step_journald_limits; cls
  step_motd_custom;   cls
  step_bbr3_link;     cls

  info_box "Готово" "Базовая настройка завершена.\nМожно закрыть окно и продолжить работу."
  cls
}

main "$@"
