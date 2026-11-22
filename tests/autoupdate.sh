#!/usr/bin/env bash
# Prueba de la actualización automática, la vuelta atrás, el congelado, el vigilante y los
# avisos (Telegram simulado). Usa su propio proyecto de Compose y no toca producción.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
PROJECT=ovpn-autotest
export SMOKE_CLIENT_DIR="$WORK/client" SMOKE_MOCK_DIR="$WORK/mock" SMOKE_MOCK_PORT=18081
export OVPN_IMAGE_TAG=autotest SMOKE_MOCK_IMAGE=ghcr.io/editech-dev/openvpn:autotest-mock
export COMPOSE_PROFILES=duckdns OVPN_USERS=alice
export ENV_FILE="$ROOT/tests/smoke.env" AUTOUPDATE_STATE_DIR="$WORK/state"
export NOTIFY_TELEGRAM_TOKEN=123456:test-token NOTIFY_TELEGRAM_CHAT_ID=42
export NOTIFY_TELEGRAM_API="http://127.0.0.1:$SMOKE_MOCK_PORT" OVPN_HOSTNAME=vpn.example.test
mkdir -p "$SMOKE_CLIENT_DIR" "$SMOKE_MOCK_DIR"
cp "$ROOT/tests/mock-http.sh" "$SMOKE_MOCK_DIR/"
chmod 777 "$SMOKE_MOCK_DIR"
REQ=$SMOKE_MOCK_DIR/requests.log
CARGS=(-- -p "$PROJECT" --env-file "$ROOT/tests/smoke.env" -f "$ROOT/compose.yaml" -f "$ROOT/tests/compose.smoke.yaml")

dc() { docker compose "${CARGS[@]:1}" --project-directory "$ROOT" "$@"; }
update() { "$ROOT/scripts/auto-update.sh" "$@" "${CARGS[@]}"; }
watchdog() { "$ROOT/scripts/watchdog.sh" "${CARGS[@]}"; }

pass() { printf '\033[32m✔ %s\033[0m\n' "$*"; }
fail() {
    printf '\033[31m✘ %s\033[0m\n' "$*"
    dc logs --no-color --tail 40 || true
    [[ -f $REQ ]] && tail -n 20 "$REQ"
    exit 1
}
cleanup() {
    # AUTOTEST_SHOW=1 muestra los avisos recibidos por el Telegram simulado.
    [[ ${AUTOTEST_SHOW:-} == 1 ]] && sent_since 0
    dc --profile test --profile duckdns down -v --remove-orphans >/dev/null 2>&1 || true
    local t
    for t in autotest autotest-mock autotest-candidate autotest-rollback autotest-failed; do
        docker rmi -f "ghcr.io/editech-dev/openvpn:$t" >/dev/null 2>&1 || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

cid_of() { dc ps -q "$1"; }
img_of() { docker inspect -f '{{.Image}}' "$(cid_of "$1")"; }
health_of() { docker inspect -f '{{.State.Health.Status}}' "$(cid_of "$1")" 2>/dev/null || echo none; }
wait_healthy() {
    local s
    for _ in $(seq 1 60); do
        if [[ $(health_of openvpn) == healthy && $(health_of duckdns) == healthy ]]; then return 0; fi
        sleep 2
    done
    for s in openvpn duckdns; do echo "$s: $(health_of "$s")"; done
    fail "los servicios no llegaron a healthy"
}
# Mensajes de Telegram recibidos por el simulador desde la marca dada.
# El cuerpo llega codificado (application/x-www-form-urlencoded): se decodifica para buscar.
sent_since() {
    local line
    tail -n +"$(($1 + 1))" "$REQ" 2>/dev/null | grep '^POST /bot123456:test-token/sendMessage' |
        while IFS= read -r line; do
            line=${line//+/ }
            printf '%b\n' "${line//%/\\x}"
        done || true
}
mark() { wc -l <"$REQ" 2>/dev/null || echo 0; }
expect_msg() { # marca patrón descripción
    local got
    got=$(sent_since "$1")
    grep -- "$2" <<<"$got" >/dev/null || fail "no llegó el aviso esperado ($3). Recibido: ${got:-nada}"
}

echo "== preparación"
docker build -q -t "ghcr.io/editech-dev/openvpn:$OVPN_IMAGE_TAG" "$ROOT/openvpn" >/dev/null
docker tag "ghcr.io/editech-dev/openvpn:$OVPN_IMAGE_TAG" "$SMOKE_MOCK_IMAGE"
dc --profile test up -d mock
dc up -d
wait_healthy
pass "openvpn y duckdns healthy"

echo "== avisos"
m=$(mark)
"$ROOT/scripts/notify.sh" --test 2>/dev/null
expect_msg "$m" 'Prueba de avisos' "notify.sh --test"
expect_msg "$m" 'vpn.example.test' "prefijo con el nombre de la instancia"
pass "notify.sh envía por Telegram con el nombre de la instancia"
m=$(mark)
"$ROOT/scripts/watchdog.sh" --boot "${CARGS[@]}" 2>/dev/null
expect_msg "$m" 'El servidor arranc' "aviso de arranque"
pass "aviso de arranque del servidor"

echo "== sin parches nuevos: no reinicia"
before=$(cid_of openvpn)
update 2>"$WORK/out" || fail "auto-update falló: $(cat "$WORK/out")"
grep 'Sin parches nuevos' "$WORK/out" >/dev/null || fail "no detectó la ausencia de cambios: $(cat "$WORK/out")"
[[ $(cid_of openvpn) == "$before" ]] || fail "reinició el servicio sin haber cambios"
pass "sin cambios de paquetes no se toca nada"

echo "== --force: despliega y verifica"
old_img=$(img_of openvpn)
m=$(mark)
update --force 2>"$WORK/out" || fail "auto-update --force falló: $(cat "$WORK/out")"
[[ $(img_of openvpn) != "$old_img" && $(img_of duckdns) == "$(img_of openvpn)" ]] || fail "no desplegó la imagen nueva en ambos servicios"
wait_healthy
expect_msg "$m" 'aplicada y verificada' "aviso de éxito"
pass "despliegue verificado y aviso de éxito"

echo "== --simulate-failure: vuelta atrás, congelado y aviso"
good_img=$(img_of openvpn)
m=$(mark)
rc=0
update --simulate-failure 2>"$WORK/out" || rc=$?
((rc == 3)) || fail "código de salida $rc (esperado 3): $(cat "$WORK/out")"
[[ $(img_of openvpn) == "$good_img" ]] || fail "no volvió a la imagen anterior"
wait_healthy
[[ -f $AUTOUPDATE_STATE_DIR/frozen ]] || fail "no quedó congelado"
expect_msg "$m" 'CONGELADAS' "aviso de fallo"
expect_msg "$m" 'Vuelta atr' "resultado de la vuelta atrás"
pass "vuelve a la versión anterior, congela y avisa"

echo "== congelado: no actualiza hasta --unfreeze"
update --force 2>"$WORK/out"
grep 'Congelado' "$WORK/out" >/dev/null || fail "actualizó estando congelado"
[[ $(img_of openvpn) == "$good_img" ]] || fail "cambió la imagen estando congelado"
update --status 2>&1 | grep 'CONGELADO' >/dev/null || fail "--status no muestra el congelado"
update --unfreeze 2>/dev/null
[[ ! -f $AUTOUPDATE_STATE_DIR/frozen ]] || fail "--unfreeze no reanudó"
pass "congelado respetado; --unfreeze lo reanuda"

echo "== fallo real de verificación (tiempo agotado)"
m=$(mark)
rc=0
AUTOUPDATE_VERIFY_TIMEOUT=0 update --force 2>"$WORK/out" || rc=$?
((rc == 3)) || fail "código de salida $rc (esperado 3)"
grep 'no quedó sana' "$WORK/out" >/dev/null || fail "no detectó la versión no sana: $(cat "$WORK/out")"
expect_msg "$m" 'CONGELADAS' "aviso de fallo real"
wait_healthy
[[ $(img_of openvpn) == "$good_img" ]] || fail "no restauró la imagen anterior"
update --unfreeze 2>/dev/null
pass "una versión que no queda sana se revierte sola"

echo "== vigilante"
m=$(mark)
watchdog
[[ -z $(sent_since "$m") ]] || fail "avisó sin que hubiera cambios"
dc stop duckdns
watchdog
expect_msg "$m" 'duckdns no est' "servicio caído"
m=$(mark)
watchdog
[[ -z $(sent_since "$m") ]] || fail "repitió el aviso del mismo estado"
dc start duckdns
wait_healthy
watchdog
expect_msg "$m" 'duckdns se recuper' "recuperación"
pass "avisa de caída y recuperación, sin repetir"

printf '\n\033[32mPruebas de actualización automática superadas\033[0m\n'
