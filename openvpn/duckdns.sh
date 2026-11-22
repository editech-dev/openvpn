#!/usr/bin/env bash
# Actualizador de DuckDNS: publica la IP pública del host cada DUCKDNS_INTERVAL segundos.
# El token nunca aparece en la línea de comandos ni en los logs (se pasa a curl por stdin).
set -Eeuo pipefail

LIB=/usr/local/lib/ovpn
# shellcheck source=openvpn/lib/common.sh
. "$LIB/common.sh"
# shellcheck source=openvpn/lib/duckdns.sh
. "$LIB/duckdns.sh"

OK_FILE=/tmp/duckdns.ok

# Duerme sin bloquear SIGTERM (docker stop responde al instante).
nap() {
    sleep "$1" &
    wait $! || true
}

request() { # url -> respuesta en stdout
    local url=$1 proto=https
    [[ ${DUCKDNS_URL:-} == http://* ]] && proto=http
    curl -fsS --max-time 20 --retry 0 --proto "=$proto" --config - <<<"url = \"$url\""
}

main() {
    trap 'info "DuckDNS: deteniendo"; exit 0' TERM INT
    load_file_var DUCKDNS_TOKEN
    local domains interval base url
    domains=$(duckdns_domains "${DUCKDNS_SUBDOMAINS:-}")
    valid_duckdns_domains "$domains" || die "DUCKDNS_SUBDOMAINS inválido o vacío: '${DUCKDNS_SUBDOMAINS:-}' (solo minúsculas, números y '-', sin .duckdns.org)"
    [[ -n ${DUCKDNS_TOKEN:-} ]] || die "DUCKDNS_TOKEN vacío (o DUCKDNS_TOKEN_FILE ilegible)"
    valid_duckdns_token "$DUCKDNS_TOKEN" || die "DUCKDNS_TOKEN con formato inválido"
    interval=${DUCKDNS_INTERVAL:-300}
    if ! [[ $interval =~ ^[0-9]+$ ]] || ((interval < 10)); then
        die "DUCKDNS_INTERVAL debe ser un número de segundos >= 10: $interval"
    fi
    base=${DUCKDNS_URL:-$DUCKDNS_DEFAULT_URL}
    [[ $base == https://* ]] || warn "DUCKDNS_URL sin HTTPS ($base): solo para pruebas"
    url=$(duckdns_build_url "$base" "$domains" "$DUCKDNS_TOKEN")
    unset DUCKDNS_TOKEN

    info "DuckDNS: actualizando '$domains' cada ${interval}s"
    local resp result ip last_ip="" fails=0
    while true; do
        if resp=$(request "$url" 2>/dev/null); then
            fails=0
            result=$(duckdns_parse "$resp")
            case $result in
                updated* | nochange*)
                    ip=${result#* }
                    touch "$OK_FILE"
                    if [[ $result == updated* ]]; then
                        info "DuckDNS: IP actualizada a $ip"
                    elif [[ $ip != "$last_ip" ]]; then
                        info "DuckDNS: IP vigente $ip (sin cambios)"
                    fi
                    last_ip=$ip
                    ;;
                ko) warn "DuckDNS respondió KO: revisa DUCKDNS_TOKEN y DUCKDNS_SUBDOMAINS" ;;
                *) warn "DuckDNS: respuesta inesperada" ;;
            esac
            nap "$interval"
        else
            fails=$((fails + 1))
            local wait_s
            wait_s=$(duckdns_backoff "$fails" "$interval")
            warn "DuckDNS: sin respuesta del servicio (intento $fails); reintento en ${wait_s}s"
            nap "$wait_s"
        fi
    done
}

main "$@"
