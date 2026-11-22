#!/usr/bin/env bash
# Envía un aviso por Telegram con la configuración NOTIFY_* del .env.
#   scripts/notify.sh "mensaje"     envía el mensaje
#   scripts/notify.sh --test        envía un mensaje de prueba (falla si no está configurado)
set -Eeuo pipefail
# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"

case ${1:-} in
    --test)
        notify "🔔 Prueba de avisos: si lees esto, los avisos por Telegram funcionan."
        ;;
    -h | --help | "")
        sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
        [[ -n ${1:-} ]]
        ;;
    *)
        rc=0
        notify "$*" || rc=$?
        # "Sin configurar" no es un error para quien llama (p. ej. systemd).
        ((rc == 2)) && rc=0
        exit "$rc"
        ;;
esac
