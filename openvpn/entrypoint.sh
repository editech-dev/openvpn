#!/usr/bin/env bash
# Entrypoint del contenedor OpenVPN.
#   server (por defecto): inicializa PKI, sincroniza usuarios, aplica NAT y arranca OpenVPN.
#   cualquier otro comando se ejecuta tal cual (ej. "ovpnctl users list", "sh").
set -Eeuo pipefail

LIB=/usr/local/lib/ovpn
# shellcheck source=openvpn/lib/common.sh
. "$LIB/common.sh"
# shellcheck source=openvpn/lib/pki.sh
. "$LIB/pki.sh"
# shellcheck source=openvpn/lib/users.sh
. "$LIB/users.sh"
# shellcheck source=openvpn/lib/render.sh
. "$LIB/render.sh"

setup_nat() {
    local iface
    iface=$(ip -4 route show default | awk '{print $5; exit}')
    [[ -n $iface ]] || die "No se encontró la interfaz de salida por defecto"
    if ! iptables -t nat -C POSTROUTING -s "$OVPN_NETWORK" -o "$iface" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -s "$OVPN_NETWORK" -o "$iface" -j MASQUERADE
    fi
    info "NAT activo: $OVPN_NETWORK -> $iface"
}

check_tun() {
    if [[ ! -c /dev/net/tun ]]; then
        die "/dev/net/tun no disponible: añade 'devices: [/dev/net/tun]' y 'cap_add: [NET_ADMIN]'"
    fi
    if [[ $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) != 1 ]]; then
        warn "net.ipv4.ip_forward=0: los clientes no tendrán salida a Internet/LAN"
    fi
}

main() {
    load_config
    mkdir -p "$OVPN_RUN_DIR"

    if [[ ${1:-server} != server ]]; then
        exec "$@"
    fi

    info "OpenVPN $(openvpn --version | awk 'NR==1{print $2}') — iniciando"
    check_tun
    with_lock pki_init
    with_lock users_sync
    exec 9>&-

    render_server_conf >"$OVPN_RUN_DIR/server.conf"
    # root crea el socket de gestión; 'nobody' (tras bajar privilegios) escribe status.log.
    chown root:nobody "$OVPN_RUN_DIR"
    chmod 0775 "$OVPN_RUN_DIR"
    install -o root -g nobody -m 0664 /dev/null "$OVPN_RUN_DIR/status.log"
    setup_nat

    if [[ -n $OVPN_HOSTNAME ]]; then info "Hostname público para clientes: $OVPN_HOSTNAME:$OVPN_PORT/$OVPN_PROTO"; else
        warn "OVPN_HOSTNAME vacío: no se podrán exportar perfiles hasta definirlo"; fi

    exec openvpn --config "$OVPN_RUN_DIR/server.conf"
}

main "$@"
