#!/usr/bin/env bash
# Prueba de humo end-to-end: PKI, exportación, conexión real, revocación y persistencia.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
export SMOKE_CLIENT_DIR="$WORK/client"
mkdir -p "$SMOKE_CLIENT_DIR"

dc() { docker compose -p ovpn-smoke --project-directory "$ROOT" --env-file "$ROOT/tests/smoke.env" \
    -f "$ROOT/compose.yaml" -f "$ROOT/tests/compose.smoke.yaml" "$@"; }

pass() { printf '\033[32m✔ %s\033[0m\n' "$*"; }
fail() {
    printf '\033[31m✘ %s\033[0m\n' "$*"
    dc logs --no-color --tail 80 || true
    exit 1
}

cleanup() {
    dc --profile test down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

wait_healthy() {

    for _ in $(seq 1 60); do
        [[ $(docker inspect -f '{{.State.Health.Status}}' "$(dc ps -q openvpn)" 2>/dev/null) == healthy ]] && return 0
        sleep 2
    done
    fail "openvpn no llegó a estado healthy"
}

# Arranca un cliente con el perfil dado y espera el resultado (ok|fail).
try_client() {
    local user=$1 expect=$2 logs
    cp "$WORK/$user.ovpn" "$SMOKE_CLIENT_DIR/client.ovpn"
    local cid
    cid=$(dc --profile test run -d --rm --no-deps client)
    for _ in $(seq 1 30); do
        logs=$(docker logs "$cid" 2>&1 || true)
        if grep -q 'Initialization Sequence Completed' <<<"$logs"; then
            if [[ $expect == ok ]]; then
                docker exec "$cid" ping -c 2 -W 2 10.99.0.1 >/dev/null || fail "$user conectó pero no hay tráfico por el túnel"
                if grep -q 'Options error' <<<"$logs"; then fail "el cliente reporta 'Options error' en la configuración recibida"; fi
                docker rm -f "$cid" >/dev/null
                pass "$user se conecta y hay tráfico por el túnel"
                return
            fi
            docker rm -f "$cid" >/dev/null
            fail "$user se conectó pero debía ser rechazado"
        fi
        sleep 1
    done
    docker rm -f "$cid" >/dev/null 2>&1 || true
    if [[ $expect == fail ]]; then
        dc logs openvpn 2>&1 | grep 'certificate revoked' >/dev/null || fail "$user no conectó, pero el servidor no reporta revocación"
        pass "$user es rechazado (certificado revocado)"
    else
        echo "$logs" | tail -20
        fail "$user no logró conectarse"
    fi
}

echo "== build"
docker build -q -t ghcr.io/editech-dev/openvpn:smoke "$ROOT/openvpn" >/dev/null && pass "imagen construida"

echo "== arranque"
dc up -d openvpn
wait_healthy && pass "servidor healthy"

echo "== exportación"
for u in alice bob; do
    dc exec -T openvpn ovpnctl export "$u" >"$WORK/$u.ovpn"
    for tag in '<ca>' '<cert>' '<key>' '<tls-crypt>' 'remote openvpn 1194'; do
        grep -qF "$tag" "$WORK/$u.ovpn" || fail "perfil de $u sin '$tag'"
    done
done
pass "perfiles exportados con material inline"
"$ROOT/scripts/export-clients.sh" --project-dir "$ROOT" --out "$WORK/exports" \
    -- -p ovpn-smoke --env-file "$ROOT/tests/smoke.env" -f "$ROOT/compose.yaml" -f "$ROOT/tests/compose.smoke.yaml" >/dev/null
[[ -s $WORK/exports/alice.ovpn && -s $WORK/exports/bob.ovpn ]] || fail "export-clients.sh no generó los perfiles"
[[ $(stat -c %a "$WORK/exports/alice.ovpn") == 600 ]] || fail "permisos del perfil distintos de 600"
pass "scripts/export-clients.sh exporta todos los usuarios con permisos 600"

echo "== conexión"
try_client alice ok
try_client bob ok

echo "== revocación (quitar bob de OVPN_USERS)"
ca_before=$(dc exec -T openvpn sh -c 'openssl x509 -in /etc/openvpn/pki/ca.crt -noout -fingerprint')
OVPN_USERS=alice dc up -d openvpn
wait_healthy
dc exec -T openvpn ovpnctl users list | grep -E '^bob +revocado' >/dev/null || fail "bob no aparece revocado"
pass "bob revocado al quitarlo de la lista"
try_client bob fail
try_client alice ok

echo "== persistencia"
OVPN_USERS=alice dc down
OVPN_USERS=alice dc up -d openvpn
wait_healthy
ca_after=$(dc exec -T openvpn sh -c 'openssl x509 -in /etc/openvpn/pki/ca.crt -noout -fingerprint')
[[ $ca_before == "$ca_after" ]] || fail "la CA cambió tras recrear el contenedor"
try_client alice ok
pass "PKI persistente tras down/up"

echo "== revocación en caliente y reemisión"
cp "$WORK/alice.ovpn" "$SMOKE_CLIENT_DIR/client.ovpn"
cid=$(dc --profile test run -d --rm --no-deps client)
for _ in $(seq 1 30); do
    docker logs "$cid" 2>&1 | grep 'Initialization Sequence Completed' >/dev/null && break
    sleep 1
done
dc exec -T openvpn ovpnctl status | grep '^alice ' >/dev/null || fail "alice no aparece en ovpnctl status"
OVPN_USERS=alice dc exec -T openvpn ovpnctl users revoke alice
gone=0
for _ in $(seq 1 15); do  # status.log se refresca cada 10 s
    if ! dc exec -T openvpn ovpnctl status | grep '^alice ' >/dev/null; then gone=1 && break; fi
    sleep 2
done
((gone)) || fail "alice sigue conectada tras revocarla"
docker rm -f "$cid" >/dev/null
pass "revoke desconecta al usuario al instante"
dc exec -T openvpn ovpnctl users reissue alice
dc exec -T openvpn ovpnctl export alice >"$WORK/alice.ovpn"
try_client alice ok
pass "reissue emite un perfil nuevo y funcional"

echo "== backup y restauración"
CA=(sh -c 'openssl x509 -in /etc/openvpn/pki/ca.crt -noout -fingerprint')
ca_before=$(dc exec -T openvpn "${CA[@]}")
SC=(-- -p ovpn-smoke --env-file "$ROOT/tests/smoke.env" -f "$ROOT/compose.yaml" -f "$ROOT/tests/compose.smoke.yaml")
OVPN_USERS=alice "$ROOT/scripts/backup-pki.sh" backup --out "$WORK/bk" "${SC[@]}" >/dev/null 2>&1
backup=$(ls "$WORK"/bk/*.tar.gz)
tar -tzf "$backup" | grep 'pki/ca.crt$' >/dev/null || fail "el backup no contiene la CA"
OVPN_USERS=alice dc down -v
OVPN_USERS=alice "$ROOT/scripts/backup-pki.sh" restore "$backup" --yes "${SC[@]}" >/dev/null 2>&1
OVPN_USERS=alice dc up -d openvpn
wait_healthy
[[ $(dc exec -T openvpn "${CA[@]}") == "$ca_before" ]] || fail "la CA restaurada no coincide"
try_client alice ok
pass "backup → borrar volumen → restore conserva la CA y los perfiles existentes"

echo "== apagado limpio (SIGTERM llega a openvpn y avisa a los clientes)"
cp "$WORK/alice.ovpn" "$SMOKE_CLIENT_DIR/client.ovpn"
cid=$(dc --profile test run -d --rm --no-deps client)
for _ in $(seq 1 30); do
    docker logs "$cid" 2>&1 | grep 'Initialization Sequence Completed' >/dev/null && break
    sleep 1
done
t0=$(date +%s)
OVPN_USERS=alice dc restart -t 10 openvpn
elapsed=$(($(date +%s) - t0))
if dc logs openvpn 2>&1 | grep 'Unexpected error when forwarding signal' >/dev/null; then
    fail "tini no puede reenviar señales a openvpn"
fi
((elapsed < 9)) || fail "el reinicio tardó ${elapsed}s: openvpn no atiende SIGTERM (lo mata SIGKILL)"
reconnected=0
for _ in $(seq 1 20); do
    if [[ $(docker logs "$cid" 2>&1 | grep -c 'Initialization Sequence Completed') -ge 2 ]]; then reconnected=1 && break; fi
    sleep 1
done
docker rm -f "$cid" >/dev/null
((reconnected)) || fail "el cliente no se reconectó en 20 s tras reiniciar el servidor"
pass "reinicio limpio en ${elapsed}s y el cliente se reconecta solo"

echo "== validación de configuración"
if OVPN_USERS='mal usuario!' dc run --rm --no-deps -T openvpn ovpnctl users list >/dev/null 2>&1; then
    fail "aceptó un nombre de usuario inválido"
fi
pass "rechaza usuarios inválidos"

printf '\n\033[32mTodas las pruebas pasaron\033[0m\n'
