#!/usr/bin/env bash
# Actualización automática de la imagen (openvpn + duckdns) con verificación y vuelta atrás.
# Pensado para ejecutarse desde el timer de systemd (scripts/install-host.sh), sin GitHub:
# reconstruye la imagen en el propio host con los últimos parches de Alpine.
set -Eeuo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

usage() {
    cat <<'USAGE'
Uso: scripts/auto-update.sh [opción] [-- <args de docker compose>]

  (sin opción)         Busca parches; si los hay, despliega, verifica y, si falla, vuelve atrás
  --dry-run            Construye y compara, pero no despliega
  --force              Despliega aunque no haya paquetes nuevos
  --simulate-failure   Despliega y simula un fallo para probar la vuelta atrás y el aviso
  --status             Estado: congelado o no, última ejecución, imágenes
  --unfreeze           Reanuda las actualizaciones tras revisar un fallo

Si una actualización falla, la versión anterior se restaura, las actualizaciones quedan
CONGELADAS y se envía un aviso por Telegram (NOTIFY_* en .env).
USAGE
}

STATE_DIR=${AUTOUPDATE_STATE_DIR:-$PROJECT_DIR/.state}
FROZEN=$STATE_DIR/frozen
LAST_RUN=$STATE_DIR/last-run
EXIT_HANDLED=3 # fallo ya gestionado y avisado (systemd lo trata como éxito)
PHASE=init

log() { msg "auto-update: $*"; }

record() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >"$LAST_RUN"; }

init_images() {
    IMAGE=$(dc config --images openvpn)
    local repo=${IMAGE%:*} tag=${IMAGE##*:}
    CANDIDATE="$repo:$tag-candidate"
    ROLLBACK="$repo:$tag-rollback"
    FAILED="$repo:$tag-failed"
}

image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null; }

packages_of() {
    docker run --rm --network none --entrypoint cat "$1" /usr/local/share/ovpn/packages.txt 2>/dev/null || true
}

# Espera a que todos los servicios estén sanos con la imagen esperada. Deja el detalle en VERIFY_DETAIL.
verify() { # imagen_esperada [timeout]
    local want=$1 timeout=${2:-} svc st ok deadline
    [[ -n $timeout ]] || timeout=$(env_get AUTOUPDATE_VERIFY_TIMEOUT 150)
    deadline=$((SECONDS + timeout))
    while :; do
        ok=1
        VERIFY_DETAIL=""
        for svc in $(expected_services); do
            st=$(service_health "$svc")
            [[ $(service_image_id "$svc") == "$want" ]] || st="$st (imagen distinta)"
            [[ $st == healthy ]] || ok=0
            VERIFY_DETAIL+="$svc=$st "
        done
        if ((ok)); then
            dc exec -T openvpn ovpnctl users list >/dev/null 2>&1 && return 0
            ok=0
            VERIFY_DETAIL+="ovpnctl=sin respuesta"
        fi
        ((SECONDS >= deadline)) && return 1
        sleep 3
    done
}

deploy() { # imagen
    docker tag "$1" "$IMAGE"
    dc up -d --remove-orphans >&2
}

# Restaura la imagen anterior, congela las actualizaciones y avisa.
rollback_and_freeze() {
    local reason=$1 logs result
    PHASE=rollback
    logs=$(dc logs --no-color --tail 12 2>&1 | tail -n 24 || true)
    log "FALLO: $reason. Volviendo a la versión anterior"
    docker tag "$CANDIDATE" "$FAILED" 2>/dev/null || true
    if deploy "$ROLLBACK" && verify "$ROLLBACK_ID" 180; then
        result="✅ Vuelta atrás completada: la VPN sigue funcionando con la versión anterior."
    else
        result="❌ CRÍTICO: la versión anterior TAMPOCO quedó sana ($VERIFY_DETAIL). Revisa la VM cuanto antes."
    fi
    printf 'desde: %s\nmotivo: %s\nresultado: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" "$result" >"$FROZEN"
    touch "$STATE_DIR/frozen.reminded"
    record "fallo: $reason"
    log "$result Actualizaciones congeladas."
    notify "🚨 Falló la actualización automática.
Motivo: $reason
$result
Las actualizaciones automáticas quedan CONGELADAS hasta revisarlo.
Para reanudar: ./scripts/auto-update.sh --unfreeze

Últimos logs:
$logs" || true
    exit "$EXIT_HANDLED"
}

on_error() {
    local line=$1
    trap - ERR
    if [[ $PHASE == deploy ]]; then
        rollback_and_freeze "error inesperado del actualizador (línea $line)"
    fi
    record "error inesperado (línea $line)"
    notify "⚠️ Error inesperado en la actualización automática (línea $line, fase $PHASE). No se cambió nada en producción. Revisa: journalctl -u openvpn-autoupdate" || true
    exit "$EXIT_HANDLED"
}

show_status() {
    if [[ -f $FROZEN ]]; then
        echo "Estado: CONGELADO"
        sed 's/^/  /' "$FROZEN"
    else
        echo "Estado: activo"
    fi
    [[ -f $LAST_RUN ]] && echo "Última ejecución: $(cat "$LAST_RUN")"
    init_images
    local ref
    for ref in "$IMAGE" "$ROLLBACK" "$FAILED"; do
        image_id "$ref" >/dev/null && printf '  %-55s %s\n' "$ref" "$(docker image inspect -f '{{.Created}}' "$ref" | cut -c1-19)"
    done
    if command -v systemctl >/dev/null && systemctl list-timers 'openvpn-*' --no-pager >/dev/null 2>&1; then
        systemctl list-timers 'openvpn-*' --no-pager
    fi
}

main() {
    local mode=run args=()
    split_compose_args args "$@"
    set -- "${args[@]}"
    case ${1:-} in
        "") ;;
        --dry-run) mode=dry ;;
        --force) mode=force ;;
        --simulate-failure) mode=simulate ;;
        --status) mode=status ;;
        --unfreeze) mode=unfreeze ;;
        -h | --help) usage && exit 0 ;;
        *) usage && exit 2 ;;
    esac

    require_docker
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    case $mode in
        status) show_status && exit 0 ;;
        unfreeze)
            if [[ -f $FROZEN ]]; then
                rm -f "$FROZEN" "$STATE_DIR/frozen.reminded"
                log "Actualizaciones reanudadas"
                notify "▶️ Actualizaciones automáticas reanudadas." || true
            else
                log "No estaban congeladas"
            fi
            exit 0
            ;;
    esac

    exec 8>"$STATE_DIR/update.lock"
    flock -w 120 8 || die "Ya hay una actualización en curso"
    trap 'on_error $LINENO' ERR

    if [[ -f $FROZEN ]]; then
        log "Congelado: no se actualiza. $(sed -n 2p "$FROZEN")"
        if [[ -z $(find "$STATE_DIR/frozen.reminded" -mtime -7 2>/dev/null) ]]; then
            notify "⏸️ Recordatorio: las actualizaciones automáticas siguen CONGELADAS.
$(cat "$FROZEN")
Para reanudar: ./scripts/auto-update.sh --unfreeze" || true
            touch "$STATE_DIR/frozen.reminded"
        fi
        exit 0
    fi
    if ! is_true "$(env_get AUTOUPDATE_ENABLED true)" && [[ $mode == run ]]; then
        log "AUTOUPDATE_ENABLED=false: no se hace nada"
        exit 0
    fi
    case $(env_get OVPN_PULL_POLICY missing) in
        missing | never | if_not_present) ;;
        *) die "OVPN_PULL_POLICY debe ser 'missing' o 'never' para actualizar la imagen local" ;;
    esac

    init_images
    PHASE=check
    local current_id
    current_id=$(service_image_id openvpn || true)
    if [[ -z $current_id ]]; then
        log "OpenVPN no está en marcha: no se actualiza (el vigilante avisa de servicios caídos)"
        record "omitido: openvpn no está en marcha"
        exit 0
    fi

    PHASE=build
    log "Construyendo imagen candidata con los últimos parches de Alpine..."
    local build_log
    if ! build_log=$(docker build --build-arg "PATCH_STAMP=$(date -u +%Y%m%dT%H%M%SZ)" \
        -t "$CANDIDATE" "$PROJECT_DIR/openvpn" 2>&1); then
        log "No se pudo construir la imagen; se mantiene la actual"
        record "fallo de construcción (se mantiene la versión actual)"
        notify "⚠️ La actualización automática no pudo construir la imagen nueva (¿sin acceso a los repositorios de Alpine?). La VPN sigue con la versión actual; se reintentará en la próxima ejecución.

$(tail -n 8 <<<"$build_log")" || true
        exit "$EXIT_HANDLED"
    fi

    local changes count
    changes=$(diff <(packages_of "$current_id") <(packages_of "$CANDIDATE") | sed -n 's/^> /  + /p; s/^< /  - /p' || true)
    count=$(grep -c '^  +' <<<"$changes" || true)
    if [[ -z $changes && $mode == run ]]; then
        log "Sin parches nuevos: no se reinicia nada"
        docker rmi "$CANDIDATE" >/dev/null
        record "ok: sin cambios"
        exit 0
    fi
    if [[ $mode == dry ]]; then
        log "Simulación (--dry-run). Cambios de paquetes:"
        printf '%s\n' "${changes:-  (ninguno)}"
        docker rmi "$CANDIDATE" >/dev/null
        exit 0
    fi

    local old_rollback
    old_rollback=$(image_id "$ROLLBACK" || true)
    ROLLBACK_ID=$current_id
    docker tag "$current_id" "$ROLLBACK"

    PHASE=deploy
    log "Desplegando ($count paquetes nuevos)..."
    local cand_id
    cand_id=$(image_id "$CANDIDATE")
    deploy "$CANDIDATE"
    if ! verify "$cand_id"; then
        rollback_and_freeze "la versión nueva no quedó sana (${VERIFY_DETAIL% })"
    fi
    if [[ $mode == simulate ]]; then
        rollback_and_freeze "simulación de fallo (--simulate-failure)"
    fi

    PHASE=cleanup
    docker rmi "$CANDIDATE" >/dev/null 2>&1 || true
    if [[ -n $old_rollback && $old_rollback != "$current_id" && $old_rollback != "$cand_id" ]]; then
        docker rmi "$old_rollback" >/dev/null 2>&1 || true
    fi
    record "ok: desplegados $count paquetes nuevos"
    log "Actualización aplicada y verificada"
    if is_true "$(env_get NOTIFY_ON_SUCCESS true)"; then
        notify "✅ Actualización automática aplicada y verificada ($count paquetes nuevos):
$(head -n 30 <<<"${changes:-  (sin cambios de paquetes)}")" || true
    fi
}


main "$@"
