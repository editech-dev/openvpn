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

Avisos por Telegram (NOTIFY_* en .env): solo dos tipos de mensaje.
  ✅ Nueva versión instalada correctamente (versión anterior → nueva y paquetes)
  🚨 Error al actualizar (versión anterior → la que se intentaba y el error); la versión
     anterior se restaura y las actualizaciones quedan en pausa hasta --unfreeze.
Las revisiones sin cambios no envían nada.
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

# Versión resumida de una imagen, p. ej. "OpenVPN 2.7.7-r0 · Alpine 3.24.4".
version_of() {
    # shellcheck disable=SC2016 # se expande dentro del contenedor
    docker run --rm --network none --entrypoint sh "$1" -c '
        v=$(sed -n "s/^openvpn-\([0-9]\)/\1/p" /usr/local/share/ovpn/packages.txt 2>/dev/null)
        [ -n "$v" ] || v=$(openvpn --version | awk "NR==1{print \$2}")
        printf "OpenVPN %s · Alpine %s" "$v" "$(cat /etc/alpine-release)"' 2>/dev/null || echo "desconocida"
}

# Compara dos listas "nombre-versión-rN" y emite "• nombre: anterior → nueva".
package_changes() { # archivo_anterior archivo_nuevo
    awk '
        function parse(s) {
            n = split(s, p, "-"); name = p[1]
            for (i = 2; i <= n - 2; i++) name = name "-" p[i]
            ver = (n >= 3) ? p[n - 1] "-" p[n] : s
        }
        FNR == NR { parse($0); old[name] = ver; next }
        { parse($0); new[name] = ver }
        END {
            for (k in new) {
                if (!(k in old)) print "• " k ": (nuevo) → " new[k]
                else if (old[k] != new[k]) print "• " k ": " old[k] " → " new[k]
            }
            for (k in old) if (!(k in new)) print "• " k ": " old[k] " → (eliminado)"
        }' "$1" "$2" | sort
}

notify_success() {
    is_true "$(env_get NOTIFY_ON_SUCCESS true)" || return 0
    notify "✅ Nueva versión instalada correctamente
Versión: $VERSION_FROM → $VERSION_TO
Paquetes actualizados ($COUNT):
$(head -n 25 <<<"$CHANGES")" || true
}

notify_error() { # error resultado [detalle]
    local text="🚨 Error al actualizar
Versión: $VERSION_FROM → ${VERSION_TO:-(no disponible)}
Error: $1"
    [[ -n ${3:-} ]] && text+="
Detalle:
$3"
    text+="
$2"
    notify "$text" || true
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

# Últimas líneas de log de los servicios que no quedaron sanos (según VERIFY_DETAIL).
failing_logs() {
    local entry svc out=""
    for entry in ${VERIFY_DETAIL:-}; do
        [[ $entry == *=* && $entry != *=healthy ]] || continue
        svc=${entry%%=*}
        [[ $svc == ovpnctl ]] && svc=openvpn
        out+=$(dc logs --no-color --tail 5 "$svc" 2>&1 | tail -n 5 || true)$'\n'
    done
    printf '%s' "${out%$'\n'}"
}

# Restaura la imagen anterior, pausa las actualizaciones y avisa.
rollback_and_freeze() {
    local reason=$1 detail=${2:-} result
    PHASE=rollback
    log "FALLO: $reason. Volviendo a la versión anterior"
    docker tag "$CANDIDATE" "$FAILED" 2>/dev/null || true
    docker rmi "$CANDIDATE" >/dev/null 2>&1 || true
    if deploy "$ROLLBACK" && verify "$ROLLBACK_ID" 180; then
        result="La VPN sigue funcionando con la versión anterior. Actualizaciones en pausa hasta revisarlo."
    else
        result="❌ CRÍTICO: la versión anterior tampoco quedó sana (${VERIFY_DETAIL% }). Hay que revisar el servidor."
    fi
    printf 'desde: %s\nversion: %s -> %s\nmotivo: %s\nresultado: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$VERSION_FROM" "${VERSION_TO:-?}" "$reason" "$result" >"$FROZEN"
    record "fallo: $reason"
    log "$result"
    notify_error "$reason" "$result" "$detail"
    exit "$EXIT_HANDLED"
}

on_error() {
    local line=$1
    trap - ERR
    if [[ $PHASE == deploy ]]; then
        rollback_and_freeze "error inesperado del actualizador (línea $line)"
    fi
    record "error inesperado (línea $line, fase $PHASE)"
    notify_error "fallo inesperado del actualizador (línea $line, fase $PHASE)" \
        "No se cambió nada: la VPN sigue con la versión actual. Detalle: journalctl -u openvpn-autoupdate"
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
                rm -f "$FROZEN"
                init_images
                docker rmi "$FAILED" >/dev/null 2>&1 || true
                log "Actualizaciones reanudadas"
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
        log "Congelado: no se actualiza ($(sed -n 's/^motivo: //p' "$FROZEN")). Reanudar: --unfreeze"
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

    VERSION_FROM=$(version_of "$current_id")
    VERSION_TO=""

    PHASE=build
    log "Construyendo imagen candidata con los últimos parches de Alpine..."
    local build_log fails_file=$STATE_DIR/build-failures fails alert_after
    if ! build_log=$(docker build --build-arg "PATCH_STAMP=$(date -u +%Y%m%dT%H%M%SZ)" \
        -t "$CANDIDATE" "$PROJECT_DIR/openvpn" 2>&1); then
        # Un fallo puntual (red, repositorio caído) no avisa: se reintenta en la próxima
        # ejecución. Solo se avisa si se repite AUTOUPDATE_BUILD_FAIL_ALERT veces seguidas.
        fails=$(($(cat "$fails_file" 2>/dev/null || echo 0) + 1))
        echo "$fails" >"$fails_file"
        alert_after=$(env_get AUTOUPDATE_BUILD_FAIL_ALERT 3)
        log "No se pudo construir la imagen (intento $fails); se mantiene la actual"
        record "fallo de construcción $fails (se mantiene la versión actual)"
        if ((fails == alert_after)); then
            notify_error "no se pudo construir la versión nueva en $fails intentos seguidos" \
                "La VPN sigue funcionando con la versión actual; se seguirá intentando." \
                "$(grep -iE 'error|fail|unable|temporary' <<<"$build_log" | tail -n 4)"
        fi
        exit "$EXIT_HANDLED"
    fi
    rm -f "$fails_file"
    VERSION_TO=$(version_of "$CANDIDATE")

    local old_list=$STATE_DIR/packages.old new_list=$STATE_DIR/packages.new
    packages_of "$current_id" >"$old_list"
    packages_of "$CANDIDATE" >"$new_list"
    CHANGES=$(package_changes "$old_list" "$new_list")
    COUNT=$(grep -c . <<<"$CHANGES" || true)
    rm -f "$old_list" "$new_list"
    if [[ -z $CHANGES && $mode == run ]]; then
        log "Sin parches nuevos: no se reinicia nada"
        docker rmi "$CANDIDATE" >/dev/null
        record "ok: sin cambios"
        exit 0
    fi
    if [[ $mode == dry ]]; then
        log "Simulación (--dry-run). Cambios de paquetes:"
        printf 'Versión: %s → %s\n%s\n' "$VERSION_FROM" "$VERSION_TO" "${CHANGES:-  (ninguno)}"
        docker rmi "$CANDIDATE" >/dev/null
        exit 0
    fi

    local old_rollback
    old_rollback=$(image_id "$ROLLBACK" || true)
    ROLLBACK_ID=$current_id
    docker tag "$current_id" "$ROLLBACK"

    PHASE=deploy
    log "Desplegando $VERSION_FROM → $VERSION_TO ($COUNT paquetes cambiados)..."
    local cand_id
    cand_id=$(image_id "$CANDIDATE")
    deploy "$CANDIDATE"
    if ! verify "$cand_id"; then
        rollback_and_freeze "la versión nueva no quedó sana (${VERIFY_DETAIL% })" "$(failing_logs)"
    fi
    if [[ $mode == simulate ]]; then
        rollback_and_freeze "simulación de fallo (prueba manual con --simulate-failure)"
    fi

    PHASE=cleanup
    docker rmi "$CANDIDATE" >/dev/null 2>&1 || true
    if [[ -n $old_rollback && $old_rollback != "$current_id" && $old_rollback != "$cand_id" ]]; then
        docker rmi "$old_rollback" >/dev/null 2>&1 || true
    fi
    record "ok: $VERSION_FROM → $VERSION_TO ($COUNT paquetes)"
    log "Actualización aplicada y verificada"
    # Un --force sin paquetes nuevos no es una versión nueva: no se avisa.
    ((COUNT > 0)) && notify_success
    return 0
}

main "$@"
