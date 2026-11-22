#!/usr/bin/env bash
# Instala en el host (systemd + apt) la actualización automática, el vigilante y los avisos.
#   sudo ./scripts/install-host.sh              instala o actualiza (idempotente)
#   sudo ./scripts/install-host.sh --uninstall  lo retira todo (no toca contenedores ni PKI)
# Lee AUTOUPDATE_* del .env del proyecto (ver docs/AUTO-UPDATE.md).
set -Eeuo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

UNIT_DIR=/etc/systemd/system
APT_CONF=/etc/apt/apt.conf.d/52openvpn-unattended
UNITS=(openvpn-autoupdate.service openvpn-autoupdate.timer openvpn-watchdog.service
    openvpn-watchdog.timer openvpn-boot-notify.service openvpn-notify-failure@.service)

render() { # plantilla
    local c
    c=$(<"$1")
    c=${c//@USER@/$RUN_USER}
    c=${c//@DIR@/$PROJECT_DIR}
    c=${c//@ONCALENDAR@/$ONCALENDAR}
    c=${c//@WATCH_INTERVAL@/$WATCH_INTERVAL}
    c=${c//@REBOOT_TIME@/$REBOOT_TIME}
    printf '%s\n' "$c"
}

uninstall() {
    systemctl disable --now openvpn-autoupdate.timer openvpn-watchdog.timer openvpn-boot-notify.service 2>/dev/null || true
    local u
    for u in "${UNITS[@]}"; do rm -f "$UNIT_DIR/$u"; done
    rm -f "$APT_CONF"
    systemctl daemon-reload
    msg "Desinstalado. Los contenedores, la PKI y .state/ no se han tocado."
}

install() {
    RUN_USER=${SUDO_USER:-}
    [[ -n $RUN_USER && $RUN_USER != root ]] || die "Ejecútalo con sudo desde tu usuario: sudo ./scripts/install-host.sh"
    id -nG "$RUN_USER" | tr ' ' '\n' | grep -x docker >/dev/null || die "$RUN_USER no pertenece al grupo docker"
    [[ $PROJECT_DIR != *[[:space:]]* ]] || die "La ruta del proyecto no puede contener espacios: $PROJECT_DIR"
    [[ -f $ENV_FILE ]] || die "No existe $ENV_FILE"

    ONCALENDAR=$(env_get AUTOUPDATE_ONCALENDAR "*-*-* 04:00:00 UTC")
    systemd-analyze calendar "$ONCALENDAR" >/dev/null 2>&1 || die "AUTOUPDATE_ONCALENDAR inválido: $ONCALENDAR"
    WATCH_INTERVAL=$(env_get WATCHDOG_INTERVAL 10min)
    systemd-analyze timespan "$WATCH_INTERVAL" >/dev/null 2>&1 || die "WATCHDOG_INTERVAL inválido: $WATCH_INTERVAL"
    REBOOT_TIME=$(env_get AUTOUPDATE_REBOOT_TIME 05:30)
    [[ $REBOOT_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "AUTOUPDATE_REBOOT_TIME debe ser HH:MM: $REBOOT_TIME"

    local u
    for u in "${UNITS[@]}"; do
        render "$PROJECT_DIR/deploy/systemd/$u.in" >"$UNIT_DIR/$u"
        chmod 0644 "$UNIT_DIR/$u"
    done
    systemctl daemon-reload
    systemctl enable --now openvpn-autoupdate.timer openvpn-watchdog.timer >/dev/null
    systemctl enable openvpn-boot-notify.service >/dev/null
    msg "Timers instalados (actualización: '$ONCALENDAR'; vigilante cada $WATCH_INTERVAL)."

    if is_true "$(env_get AUTOUPDATE_OS true)"; then
        if dpkg -s unattended-upgrades >/dev/null 2>&1; then
            render "$PROJECT_DIR/deploy/apt/52openvpn-unattended.in" >"$APT_CONF"
            chmod 0644 "$APT_CONF"
            msg "unattended-upgrades: incluye Docker y reinicia si hace falta a las $REBOOT_TIME (hora del sistema: $(date +%Z))."
        else
            msg "AVISO: unattended-upgrades no está instalado (sudo apt install unattended-upgrades); el SO no se actualizará solo."
        fi
    else
        rm -f "$APT_CONF"
        msg "AUTOUPDATE_OS=false: no se modifica unattended-upgrades."
    fi
    systemctl list-timers 'openvpn-*' --no-pager
}

[[ $EUID -eq 0 ]] || die "Requiere root: sudo $0 ${*}"
case ${1:-} in
    "") install ;;
    --uninstall) uninstall ;;
    *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' && exit 2 ;;
esac
