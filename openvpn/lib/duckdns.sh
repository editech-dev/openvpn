#!/usr/bin/env bash
# shellcheck shell=bash
# Cliente DuckDNS: funciones puras (probadas con bats). El bucle vive en duckdns.sh.

# shellcheck disable=SC2034 # se usa en duckdns.sh
DUCKDNS_DEFAULT_URL=https://www.duckdns.org/update

# Une la lista de subdominios (coma/espacio) en "a,b", quitando ".duckdns.org" si se incluyó.
duckdns_domains() {
    split_list "$1" | sed 's/\.duckdns\.org$//' | paste -sd, -
}

valid_duckdns_domains() {
    [[ -n $1 && $1 =~ ^[a-z0-9-]+(,[a-z0-9-]+)*$ ]]
}

# El token va dentro de la URL: solo se aceptan caracteres seguros (UUID).
valid_duckdns_token() {
    [[ $1 =~ ^[A-Za-z0-9-]{8,64}$ ]]
}

duckdns_build_url() { # base dominios token
    printf '%s?domains=%s&token=%s&verbose=true' "$1" "$2" "$3"
}

# Interpreta la respuesta "verbose" de DuckDNS:
#   OK\n<ipv4>\n<ipv6>\nUPDATED|NOCHANGE   o   KO
# Imprime "updated <ip>", "nochange <ip>", "ko" o "invalid".
duckdns_parse() {
    local -a l
    mapfile -t l < <(tr -d '\r' <<<"$1")
    case ${l[0]:-} in
        OK)
            if [[ ${l[3]:-} == UPDATED ]]; then echo "updated ${l[1]:-?}"; else echo "nochange ${l[1]:-?}"; fi
            ;;
        KO) echo ko ;;
        *) echo invalid ;;
    esac
}

# Espera tras un fallo de red: 30, 60, 120 ... hasta el intervalo normal.
duckdns_backoff() { # fallos_consecutivos intervalo
    local d=$((30 << ($1 > 5 ? 5 : $1 - 1)))
    ((d > $2)) && d=$2
    echo "$d"
}
