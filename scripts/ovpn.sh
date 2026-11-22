#!/usr/bin/env bash
# Administración desde el host: atajo a 'ovpnctl' dentro del contenedor.
set -Eeuo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

usage() {
    cat <<'USAGE'
Uso: scripts/ovpn.sh <comando>

  apply                    Aplica cambios del .env (recrea el contenedor y sincroniza usuarios)
  users list               Lista usuarios y su estado
  users revoke <usuario>   Revoca y desconecta a un usuario al instante
  users reissue <usuario>  Emite un certificado nuevo (renovación o re-alta tras revocación)
  status                   Clientes conectados
  config                   Configuración generada del servidor
  logs                     Sigue los logs de OpenVPN
USAGE
}

require_docker
case ${1:-} in
    apply) dc up -d --remove-orphans ;;
    logs) dc logs -f --tail 100 openvpn ;;
    users | status | config) ovpnctl "$@" ;;
    -h | --help | help | "") usage ;;
    *) usage; exit 2 ;;
esac
