#!/usr/bin/env bash
# shellcheck shell=bash
# Genera la configuración del servidor y los perfiles .ovpn de cliente.

render_server_conf() {
    local net mask d r
    net=$(cidr_network "$OVPN_NETWORK")
    mask=$(cidr_netmask "$OVPN_NETWORK")

    cat <<EOF
# Generado automáticamente por entrypoint.sh — no editar a mano.
port 1194
proto ${OVPN_PROTO}
dev tun
topology subnet
server ${net} ${mask}

ca ${EASYRSA_PKI}/ca.crt
cert ${EASYRSA_PKI}/issued/server.crt
key ${EASYRSA_PKI}/private/server.key
dh none
tls-crypt ${OVPN_DATA_DIR}/tls-crypt.key
crl-verify ${OVPN_DATA_DIR}/crl.pem
remote-cert-tls client

tls-version-min 1.2
data-ciphers ${OVPN_CIPHERS}
auth SHA256

keepalive 10 60
user nobody
group nobody
persist-tun

status ${OVPN_RUN_DIR}/status.log 10
status-version 2
management ${OVPN_RUN_DIR}/mgmt.sock unix
verb ${OVPN_VERB}
mute 20
EOF
    [[ $OVPN_PROTO == udp ]] && echo "explicit-exit-notify 1"
    is_true "$OVPN_CLIENT_TO_CLIENT" && echo "client-to-client"

    if is_true "$OVPN_REDIRECT_GATEWAY"; then
        echo 'push "redirect-gateway def1 bypass-dhcp"'
    fi
    for d in $(split_list "$OVPN_DNS"); do
        echo "push \"dhcp-option DNS ${d}\""
    done
    for r in $(split_list "$OVPN_PUSH_ROUTES"); do
        echo "push \"route $(cidr_network "$r") $(cidr_netmask "$r")\""
    done

    if [[ -n $OVPN_EXTRA_SERVER_CONFIG ]]; then
        echo "# OVPN_EXTRA_SERVER_CONFIG"
        tr '|' '\n' <<<"$OVPN_EXTRA_SERVER_CONFIG" | sed 's/^[[:space:]]*//'
    fi
}

render_client() {
    local user=$1
    [[ -n $OVPN_HOSTNAME ]] || die "Define OVPN_HOSTNAME o DUCKDNS_SUBDOMAINS para generar perfiles de cliente"
    pki_user_active "$user" || die "'$user' no tiene un certificado activo (¿está en OVPN_USERS?)"

    cat <<EOF
# Perfil OpenVPN de '${user}' — generado $(date -u +%Y-%m-%dT%H:%M:%SZ)
# CONTIENE UNA LLAVE PRIVADA: compártelo solo por un canal seguro.
client
dev tun
proto ${OVPN_PROTO}
remote ${OVPN_HOSTNAME} ${OVPN_PORT}
resolv-retry infinite
connect-retry 2 30
# Si la IP conocida no responde en 10 s, se vuelve a resolver el dominio (IP cambiada).
server-poll-timeout 10
nobind
$(is_true "$OVPN_CLIENT_PERSIST_TUN" && echo persist-tun)
remote-cert-tls server
verify-x509-name server name
# Evita fugas de DNS en Windows; el resto de clientes ignora la opción sin error.
setenv opt block-outside-dns
tls-version-min 1.2
data-ciphers ${OVPN_CIPHERS}
auth SHA256
verb 3
<ca>
$(cat "$EASYRSA_PKI/ca.crt")
</ca>
<cert>
$(openssl x509 -in "$EASYRSA_PKI/issued/$user.crt")
</cert>
<key>
$(cat "$EASYRSA_PKI/private/$user.key")
</key>
<tls-crypt>
$(cat "$OVPN_DATA_DIR/tls-crypt.key")
</tls-crypt>
EOF
}
