#!/usr/bin/env bash
# Sano si el proceso openvpn vive y status.log se actualizó hace < 60 s
# (OpenVPN solo lo escribe tras completar la inicialización, cada 10 s).
set -euo pipefail
status=/run/openvpn/status.log
pgrep -x openvpn >/dev/null || exit 1
[[ -s $status ]] || exit 1
age=$(($(date +%s) - $(stat -c %Y "$status")))
((age < 60))
