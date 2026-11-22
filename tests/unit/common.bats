#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Pruebas unitarias de openvpn/lib/common.sh

setup() {
    # shellcheck source=../../openvpn/lib/common.sh
    . "$BATS_TEST_DIRNAME/../../openvpn/lib/common.sh"
    unset OVPN_HOSTNAME DUCKDNS_SUBDOMAINS OVPN_USERS OVPN_PORT OVPN_NETWORK
}

@test "valid_username acepta nombres válidos" {
    for u in ana luis.perez tablet-ana user_01 A; do valid_username "$u"; done
}

@test "valid_username rechaza nombres inválidos y 'server'" {
    for u in "" server "a b" "ana;rm" ".oculto" "-x" "ñandu" "$(printf 'a%.0s' {1..65})"; do
        run valid_username "$u"
        [ "$status" -ne 0 ]
    done
}

@test "valid_port" {
    valid_port 1
    valid_port 1194
    valid_port 65535
    run ! valid_port 0
    run ! valid_port 65536
    run ! valid_port abc
}

@test "valid_cidr" {
    valid_cidr 10.8.0.0/24
    valid_cidr 192.168.1.0/16
    run ! valid_cidr 10.8.0.0
    run ! valid_cidr 300.1.1.1/24
    run ! valid_cidr 10.8.0.0/33
}

@test "cidr_netmask y cidr_network" {
    [ "$(cidr_netmask 10.8.0.0/24)" = 255.255.255.0 ]
    [ "$(cidr_netmask 10.0.0.0/16)" = 255.255.0.0 ]
    [ "$(cidr_netmask 10.0.0.0/29)" = 255.255.255.248 ]
    [ "$(cidr_network 192.168.1.77/24)" = 192.168.1.0 ]
}

@test "split_list separa por coma/espacio y elimina duplicados" {
    run split_list " ana, luis ,ana  pedro,,"
    [ "$output" = "$(printf 'ana\nluis\npedro')" ]
}

@test "load_config deriva OVPN_HOSTNAME de DUCKDNS_SUBDOMAINS" {
    DUCKDNS_SUBDOMAINS="mivpn,otro"
    load_config
    [ "$OVPN_HOSTNAME" = mivpn.duckdns.org ]
}

@test "load_config respeta OVPN_HOSTNAME explícito" {
    DUCKDNS_SUBDOMAINS=mivpn OVPN_HOSTNAME=vpn.example.com
    load_config
    [ "$OVPN_HOSTNAME" = vpn.example.com ]
}

@test "load_config falla con usuario inválido" {
    OVPN_USERS="ana,mal usuario!"
    run load_config
    [ "$status" -ne 0 ]
    [[ $output == *"Usuario inválido"* ]]
}

@test "load_config falla con puerto o red inválidos" {
    OVPN_PORT=99999 run load_config
    [ "$status" -ne 0 ]
    OVPN_PORT=1194 OVPN_NETWORK=10.8.0.0/8 run load_config
    [ "$status" -ne 0 ]
}
