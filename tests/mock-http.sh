#!/usr/bin/env bash
# Servidor HTTP mínimo para pruebas (DuckDNS y Telegram simulados). Se ejecuta con:
#   socat TCP-LISTEN:80,fork,reuseaddr SYSTEM:/mock/mock-http.sh
# Registra cada petición en /mock/requests.log (línea "MÉTODO RUTA" + cuerpo).
set -uo pipefail
LOG=${MOCK_LOG:-/mock/requests.log}

read -r method path _ || exit 0
len=0
while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -z $line ]] && break
    if [[ ${line,,} =~ ^content-length:\ *([0-9]+) ]]; then len=${BASH_REMATCH[1]}; fi
done
body=""
((len > 0)) && body=$(head -c "$len")
printf '%s %s %s\n' "$method" "$path" "$body" >>"$LOG"

reply() { printf 'HTTP/1.1 %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' "$1" "${#2}" "$2"; }

case $path in
    /update\?*token=test-token-ok*) reply "200 OK" $'OK\n203.0.113.7\n\nUPDATED' ;;
    /update\?*) reply "200 OK" "KO" ;;
    /bot*/sendMessage) reply "200 OK" '{"ok":true}' ;;
    *) reply "404 Not Found" "no" ;;
esac
