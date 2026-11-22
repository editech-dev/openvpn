#!/usr/bin/env bash
# shellcheck shell=bash
# Utilidades comunes: logging, validación y carga de configuración.

# ---------- logging ----------
_log() { printf '%s [%-5s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }
info() { _log INFO "$*"; }
warn() { _log WARN "$*"; }
die() {
    _log ERROR "$*"
    exit 1
}

# ---------- helpers ----------
is_true() {
    case "${1,,}" in
        1 | true | yes | on) return 0 ;;
        *) return 1 ;;
    esac
}

# Convierte una lista separada por comas/espacios en líneas únicas (orden preservado).
split_list() {
    tr ', \t' '\n' <<<"${1:-}" | sed '/^$/d' | awk '!seen[$0]++'
}

# ---------- validadores ----------
valid_username() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] && [[ $1 != "server" ]]
}

valid_port() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_ipv4() {
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do
        ((10#$o <= 255)) || return 1
    done
}

valid_cidr() {
    [[ $1 == */* ]] || return 1
    local ip=${1%/*} bits=${1#*/}
    [[ $bits =~ ^[0-9]{1,2}$ ]] && ((10#$bits >= 1 && 10#$bits <= 32)) && valid_ipv4 "$ip"
}

valid_hostname() {
    [[ ${#1} -le 253 ]] && [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

# ---------- red ----------
_ip2int() {
    local IFS=. a b c d
    read -r a b c d <<<"$1"
    echo $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}
_int2ip() { printf '%d.%d.%d.%d' $(($1 >> 24 & 255)) $(($1 >> 16 & 255)) $(($1 >> 8 & 255)) $(($1 & 255)); }

cidr_netmask() {
    local bits=${1#*/}
    _int2ip $(((0xffffffff << (32 - bits)) & 0xffffffff))
}

cidr_network() {
    local bits=${1#*/} mask ip
    mask=$(((0xffffffff << (32 - bits)) & 0xffffffff))
    ip=$(_ip2int "${1%/*}")
    _int2ip $((ip & mask))
}

# ---------- secretos ----------
# Si VAR_FILE está definida, carga su contenido en VAR (patrón Docker secrets).
load_file_var() {
    local var=$1 file_var="${1}_FILE"
    if [[ -n ${!file_var:-} ]]; then
        [[ -r ${!file_var} ]] || die "No se puede leer ${file_var}=${!file_var}"
        printf -v "$var" '%s' "$(<"${!file_var}")"
        export "${var?}"
    fi
}

# ---------- configuración ----------
# Aplica valores por defecto y valida. Falla rápido con mensajes claros.
load_config() {
    : "${OVPN_DATA_DIR:=/etc/openvpn}"
    : "${OVPN_RUN_DIR:=/run/openvpn}"
    : "${OVPN_PORT:=1194}"
    : "${OVPN_PROTO:=udp}"
    : "${OVPN_NETWORK:=10.8.0.0/24}"
    : "${OVPN_DNS:=1.1.1.1,9.9.9.9}"
    : "${OVPN_REDIRECT_GATEWAY:=true}"
    : "${OVPN_PUSH_ROUTES:=}"
    : "${OVPN_USERS:=}"
    : "${OVPN_REVOKE_REMOVED:=true}"
    : "${OVPN_CLIENT_CERT_DAYS:=825}"
    : "${OVPN_SERVER_CERT_DAYS:=1825}"
    : "${OVPN_CA_DAYS:=3650}"
    : "${OVPN_CA_CN:=openvpn-ca}"
    : "${OVPN_CIPHERS:=AES-256-GCM:CHACHA20-POLY1305:AES-128-GCM}"
    : "${OVPN_CLIENT_TO_CLIENT:=false}"
    : "${OVPN_EXTRA_SERVER_CONFIG:=}"
    : "${OVPN_VERB:=3}"
    # false (recomendado con DNS dinámico): al reconectar se retiran las rutas del túnel
    # para poder volver a resolver el dominio si la IP del servidor cambió.
    : "${OVPN_CLIENT_PERSIST_TUN:=false}"

    OVPN_PROTO=${OVPN_PROTO,,}
    [[ $OVPN_PROTO == udp || $OVPN_PROTO == tcp ]] || die "OVPN_PROTO debe ser 'udp' o 'tcp' (valor: $OVPN_PROTO)"
    valid_port "$OVPN_PORT" || die "OVPN_PORT inválido: $OVPN_PORT"
    valid_cidr "$OVPN_NETWORK" || die "OVPN_NETWORK debe ser un CIDR IPv4 (ej. 10.8.0.0/24): $OVPN_NETWORK"
    local bits=${OVPN_NETWORK#*/}
    ((bits >= 16 && bits <= 29)) || die "OVPN_NETWORK debe tener prefijo entre /16 y /29: $OVPN_NETWORK"

    local d r u n
    for d in $(split_list "$OVPN_DNS"); do
        valid_ipv4 "$d" || die "OVPN_DNS contiene una IP inválida: $d"
    done
    for r in $(split_list "$OVPN_PUSH_ROUTES"); do
        valid_cidr "$r" || die "OVPN_PUSH_ROUTES contiene un CIDR inválido: $r"
    done
    for n in OVPN_CLIENT_CERT_DAYS OVPN_SERVER_CERT_DAYS OVPN_CA_DAYS OVPN_VERB; do
        [[ ${!n} =~ ^[0-9]+$ ]] || die "$n debe ser numérico: ${!n}"
    done
    for u in $(split_list "$OVPN_USERS"); do
        valid_username "$u" || die "Usuario inválido en OVPN_USERS: '$u' (permitido: letras, números, '_', '.', '-'; máx. 64; 'server' reservado)"
    done
    [[ $OVPN_CIPHERS =~ ^[A-Za-z0-9:-]+$ ]] || die "OVPN_CIPHERS inválido: $OVPN_CIPHERS"

    # Hostname público: explícito o derivado del primer subdominio DuckDNS.
    if [[ -z ${OVPN_HOSTNAME:-} && -n ${DUCKDNS_SUBDOMAINS:-} ]]; then
        OVPN_HOSTNAME="$(split_list "$DUCKDNS_SUBDOMAINS" | head -n1)"
        [[ $OVPN_HOSTNAME == *.* ]] || OVPN_HOSTNAME="${OVPN_HOSTNAME}.duckdns.org"
    fi
    : "${OVPN_HOSTNAME:=}"
    if [[ -n $OVPN_HOSTNAME ]]; then
        valid_hostname "$OVPN_HOSTNAME" || die "OVPN_HOSTNAME inválido: $OVPN_HOSTNAME"
    fi

    export OVPN_DATA_DIR OVPN_RUN_DIR OVPN_PORT OVPN_PROTO OVPN_NETWORK OVPN_DNS \
        OVPN_REDIRECT_GATEWAY OVPN_PUSH_ROUTES OVPN_USERS OVPN_REVOKE_REMOVED \
        OVPN_CLIENT_CERT_DAYS OVPN_SERVER_CERT_DAYS OVPN_CA_DAYS OVPN_CA_CN \
        OVPN_CIPHERS OVPN_CLIENT_TO_CLIENT OVPN_EXTRA_SERVER_CONFIG OVPN_VERB OVPN_HOSTNAME \
        OVPN_CLIENT_PERSIST_TUN
}

# Bloqueo exclusivo para operaciones que modifican la PKI.
with_lock() {
    mkdir -p "$OVPN_RUN_DIR"
    exec 9>"$OVPN_RUN_DIR/pki.lock"
    flock -x 9 || die "No se pudo obtener el bloqueo de la PKI"
    "$@"
}
