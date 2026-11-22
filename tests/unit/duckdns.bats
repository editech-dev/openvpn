#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Pruebas unitarias de openvpn/lib/duckdns.sh

setup() {
    # shellcheck source=../../openvpn/lib/common.sh
    . "$BATS_TEST_DIRNAME/../../openvpn/lib/common.sh"
    # shellcheck source=../../openvpn/lib/duckdns.sh
    . "$BATS_TEST_DIRNAME/../../openvpn/lib/duckdns.sh"
}

@test "duckdns_parse: actualizado" {
    run duckdns_parse $'OK\n203.0.113.7\n\nUPDATED'
    [ "$output" = "updated 203.0.113.7" ]
}

@test "duckdns_parse: sin cambios (y tolera CRLF)" {
    run duckdns_parse $'OK\r\n203.0.113.7\r\n\r\nNOCHANGE\r\n'
    [ "$output" = "nochange 203.0.113.7" ]
}

@test "duckdns_parse: KO y respuestas inesperadas" {
    run duckdns_parse "KO"
    [ "$output" = "ko" ]
    run duckdns_parse "<html>error</html>"
    [ "$output" = "invalid" ]
    run duckdns_parse ""
    [ "$output" = "invalid" ]
}

@test "duckdns_domains une la lista y quita .duckdns.org" {
    run duckdns_domains "mivpn, otra.duckdns.org mivpn"
    [ "$output" = "mivpn,otra" ]
}

@test "valid_duckdns_domains" {
    valid_duckdns_domains "mivpn"
    valid_duckdns_domains "mi-vpn,otra2"
    run ! valid_duckdns_domains ""
    run ! valid_duckdns_domains "MiVPN"
    run ! valid_duckdns_domains "a&token=x"
}

@test "valid_duckdns_token rechaza caracteres que alterarían la URL" {
    valid_duckdns_token "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
    run ! valid_duckdns_token 'abc"def12'
    run ! valid_duckdns_token "abcd1234&x=1"
    run ! valid_duckdns_token "corto"
}

@test "duckdns_backoff crece hasta el intervalo" {
    [ "$(duckdns_backoff 1 300)" = 30 ]
    [ "$(duckdns_backoff 2 300)" = 60 ]
    [ "$(duckdns_backoff 3 300)" = 120 ]
    [ "$(duckdns_backoff 9 300)" = 300 ]
    [ "$(duckdns_backoff 1 10)" = 10 ]
}
