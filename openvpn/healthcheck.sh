#!/usr/bin/env bash
# Healthcheck de la imagen.
#   (sin argumentos) OpenVPN: el proceso vive y status.log se actualizó hace < 60 s
#                    (OpenVPN solo lo escribe tras completar la inicialización, cada 10 s).
#   duckdns          La última actualización correcta tiene menos de 3 intervalos.
set -euo pipefail

age_of() { echo $(($(date +%s) - $(stat -c %Y "$1"))); }

if [[ ${1:-} == duckdns ]]; then
    ok=/tmp/duckdns.ok
    [[ -e $ok ]] || exit 1
    (($(age_of "$ok") < 3 * ${DUCKDNS_INTERVAL:-300} + 60))
    exit
fi

status=/run/openvpn/status.log
pgrep -x openvpn >/dev/null || exit 1
[[ -s $status ]] || exit 1
(($(age_of "$status") < 60))
