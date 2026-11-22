#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Pruebas unitarias de scripts/_common.sh (lectura del .env sin "source").

setup() {
    export ENV_FILE="$BATS_TEST_TMPDIR/.env"
    cat >"$ENV_FILE" <<'ENV'
# comentario
PLAIN=valor
QUOTED="con espacios # no es comentario"
SINGLE='simple'
INLINE=abc   # comentario en línea
EMPTY=
DUP=uno
DUP=dos
DANGER=$(touch /tmp/nunca-ejecutar)
ENV
    # shellcheck source=../../scripts/_common.sh
    . "$BATS_TEST_DIRNAME/../../scripts/_common.sh"
}

@test "env_get lee valores simples, entre comillas y con comentario en línea" {
    [ "$(env_get PLAIN)" = "valor" ]
    [ "$(env_get QUOTED)" = "con espacios # no es comentario" ]
    [ "$(env_get SINGLE)" = "simple" ]
    [ "$(env_get INLINE)" = "abc" ]
}

@test "env_get: vacío, por defecto, última definición gana" {
    [ "$(env_get EMPTY def)" = "" ]
    [ "$(env_get NOEXISTE def)" = "def" ]
    [ "$(env_get DUP)" = "dos" ]
}

@test "env_get: el entorno tiene prioridad sobre el .env" {
    PLAIN=delentorno
    [ "$(env_get PLAIN)" = "delentorno" ]
}

@test "env_get no ejecuta el contenido del .env" {
    [ "$(env_get DANGER)" = '$(touch /tmp/nunca-ejecutar)' ]
    [ ! -e /tmp/nunca-ejecutar ]
}

@test "is_true" {
    is_true true
    is_true YES
    is_true 1
    run ! is_true false
    run ! is_true ""
}
