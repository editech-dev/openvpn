#!/usr/bin/env bats
# Pruebas de la generación de server.conf

setup() {
    LIB="$BATS_TEST_DIRNAME/../../openvpn/lib"
    . "$LIB/common.sh"
    . "$LIB/pki.sh"
    . "$LIB/render.sh"
    unset OVPN_REDIRECT_GATEWAY OVPN_PUSH_ROUTES OVPN_EXTRA_SERVER_CONFIG OVPN_PROTO
    OVPN_RUN_DIR=$BATS_TEST_TMPDIR
    EASYRSA_PKI=/etc/openvpn/pki
}

@test "full tunnel por defecto" {
    load_config
    run render_server_conf
    [[ $output == *'push "redirect-gateway def1 bypass-dhcp"'* ]]
    [[ $output == *'server 10.8.0.0 255.255.255.0'* ]]
    [[ $output == *'explicit-exit-notify 1'* ]]
}

@test "split tunnel con rutas" {
    OVPN_REDIRECT_GATEWAY=false OVPN_PUSH_ROUTES=192.168.1.0/24,10.20.0.0/16
    load_config
    run render_server_conf
    [[ $output != *redirect-gateway* ]]
    [[ $output == *'push "route 192.168.1.0 255.255.255.0"'* ]]
    [[ $output == *'push "route 10.20.0.0 255.255.0.0"'* ]]
}

@test "tcp no usa explicit-exit-notify" {
    OVPN_PROTO=tcp
    load_config
    run render_server_conf
    [[ $output == *'proto tcp'* ]]
    [[ $output != *explicit-exit-notify* ]]
}

@test "configuración extra separada por |" {
    OVPN_EXTRA_SERVER_CONFIG='max-clients 20| duplicate-cn'
    load_config
    run render_server_conf
    [[ $output == *$'max-clients 20\nduplicate-cn'* ]]
}

@test "la CRL se sirve desde OVPN_RUN_DIR (legible por nobody), no desde OVPN_DATA_DIR" {
    load_config
    run render_server_conf
    [[ $output == *"crl-verify $OVPN_RUN_DIR/crl.pem"* ]]
    [[ $output != *"crl-verify $OVPN_DATA_DIR/"* ]]
}
