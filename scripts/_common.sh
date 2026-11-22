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

# Ejecuta ovpnctl en el contenedor en marcha o, si está parado, en uno efímero.
ovpnctl() {
    if openvpn_running; then
        dc exec -T openvpn ovpnctl "$@"
    else
        dc run --rm --no-deps -T openvpn ovpnctl "$@"
    fi
}
