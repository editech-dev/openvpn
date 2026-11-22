#!/usr/bin/env bash
# shellcheck shell=bash
# Funciones compartidas por los scripts del host.

PROJECT_DIR=${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
COMPOSE_ARGS=()

msg() { printf '%s\n' "$*" >&2; }
is_true() {
    case "${1,,}" in
        1 | true | yes | on) return 0 ;;
        *) return 1 ;;
    esac
}
die() {
    msg "ERROR: $*"
    exit 1
}

dc() { docker compose --project-directory "$PROJECT_DIR" "${COMPOSE_ARGS[@]}" "$@"; }

require_docker() {
    command -v docker >/dev/null || die "docker no está instalado"
    docker compose version >/dev/null 2>&1 || die "docker compose (v2) no está disponible"
}

openvpn_running() { [[ -n $(dc ps -q --status running openvpn 2>/dev/null) ]]; }

# Garantiza que la imagen existe ANTES de un "run" cuya salida se captura: si Compose
# tuviera que descargarla o construirla, su progreso se mezclaría con stdout.
ensure_image() {
    local image
    image=$(dc config --images openvpn)
    docker image inspect "$image" >/dev/null 2>&1 && return 0
    msg "Preparando la imagen $image ..."
    dc pull --quiet openvpn >&2 2>/dev/null || dc build openvpn >&2 || die "No se pudo obtener la imagen $image"
}

# Ejecuta un comando en un contenedor efímero del servicio openvpn (no publica puertos).
run_oneoff() {
    ensure_image
    dc run --rm --no-deps -T "$@"
}

# Ejecuta ovpnctl en el contenedor en marcha o, si está parado, en uno efímero.
ovpnctl() {
    if openvpn_running; then
        dc exec -T openvpn ovpnctl "$@"
    else
        run_oneoff openvpn ovpnctl "$@"
    fi
}

# Admite "-- <args de docker compose>" al final de la línea de comandos de cualquier script.
split_compose_args() {
    local -n _out=$1
    shift
    _out=()
    while (($#)); do
        if [[ $1 == -- ]]; then
            shift
            COMPOSE_ARGS=("$@")
            return
        fi
        _out+=("$1")
        shift
    done
}

# ---------- configuración del host (.env) ----------
ENV_FILE=${ENV_FILE:-$PROJECT_DIR/.env}

# Valor de una variable: entorno del proceso o, si no está definida, el .env del proyecto.
# No se hace "source" del .env (podría contener caracteres que la shell interpretaría).
env_get() {
    local key=$1 def=${2:-} line val
    if [[ -n ${!key+x} ]]; then
        printf '%s' "${!key}"
        return
    fi
    if [[ -r $ENV_FILE ]]; then
        line=$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n1 || true)
        if [[ -n $line ]]; then
            val=${line#*=}
            val=${val%$'\r'}
            if [[ $val =~ ^\"(.*)\"$ || $val =~ ^\'(.*)\'$ ]]; then
                val=${BASH_REMATCH[1]}
            else
                val=$(sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//' <<<"$val")
            fi
            printf '%s' "$val"
            return
        fi
    fi
    printf '%s' "$def"
}

# ---------- estado de los servicios ----------
# healthy | unhealthy | starting | running (sin healthcheck) | exited | restarting | missing
service_health() {
    local cid
    cid=$(dc ps -a -q "$1" 2>/dev/null | head -n1 || true)
    [[ -n $cid ]] || {
        echo missing
        return
    }
    docker inspect -f '{{if not .State.Running}}{{.State.Status}}{{else if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' \
        "$cid" 2>/dev/null || echo missing
}

service_image_id() {
    local cid
    cid=$(dc ps -q "$1" 2>/dev/null || true)
    [[ -n $cid ]] && docker inspect -f '{{.Image}}' "$cid" 2>/dev/null
}

# Servicios que deberían estar en marcha (incluye duckdns si su perfil está activo).
expected_services() { dc config --services 2>/dev/null; }

# ---------- avisos ----------
instance_name() {
    local h
    h=$(env_get OVPN_HOSTNAME)
    if [[ -z $h ]]; then
        h=$(env_get DUCKDNS_SUBDOMAINS)
        h=${h%%,*}
        [[ -n $h && $h != *.* ]] && h="$h.duckdns.org"
    fi
    printf '%s' "${h:-$(hostname)}"
}

# Envía un aviso por Telegram. Devuelve 0 si se envió, 1 si falló y 2 si no está configurado.
# El token va en la URL, que se pasa a curl por stdin: no aparece en la lista de procesos.
notify() {
    local text token chat api
    text="[$(instance_name)] $*"
    text=${text:0:3900}
    token=$(env_get NOTIFY_TELEGRAM_TOKEN)
    chat=$(env_get NOTIFY_TELEGRAM_CHAT_ID)
    api=$(env_get NOTIFY_TELEGRAM_API https://api.telegram.org)
    if [[ -z $token || -z $chat ]]; then
        msg "Aviso (Telegram sin configurar): ${text%%$'\n'*}"
        return 2
    fi
    if ! [[ $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ && $chat =~ ^-?[0-9]+$ ]]; then
        msg "NOTIFY_TELEGRAM_TOKEN o NOTIFY_TELEGRAM_CHAT_ID con formato inválido"
        return 1
    fi
    if curl -fsS --max-time 20 -o /dev/null --config - \
        --data-urlencode "chat_id=$chat" --data-urlencode "text=$text" \
        <<<"url = \"$api/bot$token/sendMessage\""; then
        msg "Aviso enviado: ${text%%$'\n'*}"
    else
        msg "No se pudo enviar el aviso por Telegram"
        return 1
    fi
}
