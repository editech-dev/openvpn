#!/usr/bin/env bash
# Vigilante: avisa por Telegram cuando un servicio deja de estar sano y cuando se recupera.
# Solo avisa en los CAMBIOS de estado (sin repetir). Lo ejecuta un timer de systemd.
#   scripts/watchdog.sh          comprueba los servicios
#   scripts/watchdog.sh --boot   avisa de que el servidor arrancó (reinicio)
set -Eeuo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

STATE_DIR=${AUTOUPDATE_STATE_DIR:-$PROJECT_DIR/.state}

heartbeat() { # ok|fail
    local url
    url=$(env_get NOTIFY_HEARTBEAT_URL)
    [[ -n $url ]] || return 0
    [[ $url == https://* ]] || {
        msg "NOTIFY_HEARTBEAT_URL debe usar https"
        return 0
    }
    [[ $1 == fail ]] && url="${url%/}/fail"
    curl -fsS --max-time 15 -o /dev/null --config - <<<"url = \"$url\"" || msg "No se pudo enviar el latido"
}

# Estado legible para el aviso.
human() {
    case $1 in
        healthy) echo "sano" ;;
        unhealthy) echo "no responde (unhealthy)" ;;
        exited) echo "detenido" ;;
        restarting) echo "reiniciándose en bucle" ;;
        missing) echo "no existe el contenedor" ;;
        *) echo "$1" ;;
    esac
}

check() {
    local svc st prev all_ok=1 file logs
    if ! docker info >/dev/null 2>&1; then
        st=docker-caido
        prev=$(cat "$STATE_DIR/watch-docker" 2>/dev/null || echo ok)
        if [[ $prev != "$st" ]]; then
            notify "⚠️ Docker no responde en el servidor: la VPN probablemente está caída." || true
            echo "$st" >"$STATE_DIR/watch-docker"
        fi
        heartbeat fail
        return
    fi
    if [[ $(cat "$STATE_DIR/watch-docker" 2>/dev/null) == docker-caido ]]; then
        notify "✅ Docker vuelve a responder." || true
        echo ok >"$STATE_DIR/watch-docker"
    fi

    for svc in $(expected_services); do
        st=$(service_health "$svc")
        # Arrancando: aún no hay veredicto; se decide en la próxima vuelta.
        [[ $st == starting ]] && continue
        file="$STATE_DIR/watch-$svc"
        prev=$(cat "$file" 2>/dev/null || echo healthy)
        [[ $st == healthy ]] || all_ok=0
        [[ $st == "$prev" ]] && continue
        if [[ $st == healthy ]]; then
            notify "✅ $svc se recuperó (estaba: $(human "$prev"))." || true
        else
            logs=$(dc logs --no-color --tail 10 "$svc" 2>&1 | tail -n 10 || true)
            notify "⚠️ $svc no está sano: $(human "$st") (antes: $(human "$prev")).
Últimos logs:
$logs" || true
        fi
        echo "$st" >"$file"
    done
    if ((all_ok)); then heartbeat ok; else heartbeat fail; fi
}

main() {
    local args=()
    split_compose_args args "$@"
    set -- "${args[@]}"
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    case ${1:-} in
        --boot)
            notify "🔄 El servidor arrancó (encendido o reinicio desde $(uptime -s 2>/dev/null || echo '?'), kernel $(uname -r))." || true
            ;;
        "")
            # Durante una actualización los reinicios son esperados: no se vigila.
            exec 8>"$STATE_DIR/update.lock"
            flock -n 8 || exit 0
            check
            ;;
        *)
            sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'
            exit 2
            ;;
    esac
}

main "$@"
