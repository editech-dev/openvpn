#!/usr/bin/env bash
# shellcheck shell=bash
# Funciones compartidas por los scripts del host.

PROJECT_DIR=${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
COMPOSE_ARGS=()

msg() { printf '%s\n' "$*" >&2; }
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
