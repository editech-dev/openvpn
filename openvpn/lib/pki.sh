#!/usr/bin/env bash
# shellcheck shell=bash
# Gestión de la PKI con easy-rsa 3 (curva elíptica, sin passphrase en las llaves).

pki_env() {
    export EASYRSA=/usr/share/easy-rsa
    export EASYRSA_PKI="$OVPN_DATA_DIR/pki"
    export EASYRSA_BATCH=1
    export EASYRSA_SILENT=1
    export EASYRSA_ALGO=ec
    export EASYRSA_CURVE=prime256v1
    export EASYRSA_DIGEST=sha256
    # La CRL caduca: si vence, OpenVPN rechaza a TODOS los clientes. Se regenera en cada
    # arranque y en cada cambio, con una vigencia larga.
    export EASYRSA_CRL_DAYS=3650
}

easyrsa() {
    "$EASYRSA/easyrsa" "$@" >/dev/null 2>"$OVPN_RUN_DIR/easyrsa.err" || {
        cat "$OVPN_RUN_DIR/easyrsa.err" >&2
        die "easyrsa $1 falló"
    }
}

pki_init() {
    pki_env
    mkdir -p "$OVPN_DATA_DIR" "$OVPN_RUN_DIR"
    chmod 700 "$OVPN_DATA_DIR"

    if [[ ! -f $EASYRSA_PKI/index.txt ]]; then
        info "Inicializando PKI en $EASYRSA_PKI"
        rm -rf "$EASYRSA_PKI"
        easyrsa init-pki
    fi
    if [[ ! -f $EASYRSA_PKI/ca.crt ]]; then
        info "Creando CA '$OVPN_CA_CN' (vigencia ${OVPN_CA_DAYS} días)"
        EASYRSA_REQ_CN="$OVPN_CA_CN" EASYRSA_CA_EXPIRE="$OVPN_CA_DAYS" easyrsa build-ca nopass
    fi
    if [[ ! -f $EASYRSA_PKI/issued/server.crt ]]; then
        info "Emitiendo certificado del servidor (vigencia ${OVPN_SERVER_CERT_DAYS} días)"
        EASYRSA_CERT_EXPIRE="$OVPN_SERVER_CERT_DAYS" easyrsa build-server-full server nopass
    fi
    if [[ ! -f $OVPN_DATA_DIR/tls-crypt.key ]]; then
        info "Generando llave tls-crypt"
        openvpn --genkey tls-crypt "$OVPN_DATA_DIR/tls-crypt.key" >/dev/null
        chmod 600 "$OVPN_DATA_DIR/tls-crypt.key"
    fi
    pki_check_expiry
    pki_gen_crl
}

pki_gen_crl() {
    pki_env
    easyrsa gen-crl
    # OpenVPN baja privilegios a 'nobody' y relee la CRL en cada conexión: debe ser legible.
    install -m 0644 "$EASYRSA_PKI/crl.pem" "$OVPN_DATA_DIR/crl.pem"
}

pki_check_expiry() {
    local f
    for f in "$EASYRSA_PKI/ca.crt" "$EASYRSA_PKI/issued/server.crt"; do
        if ! openssl x509 -in "$f" -noout -checkend $((30 * 86400)) >/dev/null; then
            warn "El certificado $(basename "$f") vence en menos de 30 días: $(cert_expiry "$f")"
        fi
    done
}

# ---------- consultas sobre index.txt ----------
# Formato: estado \t expira \t revocado \t serial \t archivo \t /CN=nombre
_index_users() {
    local status=$1
    [[ -f $EASYRSA_PKI/index.txt ]] || return 0
    awk -F'\t' -v s="$status" '$1 == s {
        cn = $6; sub(/.*\/CN=/, "", cn); sub(/\/.*/, "", cn)
        if (cn != "server") print cn
    }' "$EASYRSA_PKI/index.txt" | awk '!seen[$0]++'
}

pki_valid_users() { _index_users V; }
pki_revoked_users() { _index_users R; }

# Un usuario está activo si tiene certificado emitido vigente en issued/.
pki_user_active() {
    [[ -f $EASYRSA_PKI/issued/$1.crt ]] && pki_valid_users | grep -xF -- "$1" >/dev/null
}

cert_expiry() { openssl x509 -in "$1" -noout -enddate | cut -d= -f2; }

cert_expired() { ! openssl x509 -in "$1" -noout -checkend 0 >/dev/null; }

# ---------- operaciones de cliente ----------
pki_issue_client() {
    local user=$1
    info "Emitiendo certificado para '$user' (vigencia ${OVPN_CLIENT_CERT_DAYS} días)"
    EASYRSA_CERT_EXPIRE="$OVPN_CLIENT_CERT_DAYS" easyrsa build-client-full "$user" nopass
}

pki_revoke_client() {
    local user=$1
    info "Revocando certificado de '$user'"
    easyrsa revoke "$user" cessationOfOperation
    # easy-rsa 3.2 mueve cert/llave a revoked/; limpiamos restos para permitir reemisión explícita.
    rm -f "$EASYRSA_PKI/issued/$user.crt" "$EASYRSA_PKI/private/$user.key" "$EASYRSA_PKI/reqs/$user.req"
}
