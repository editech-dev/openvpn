#!/usr/bin/env bash
# shellcheck shell=bash
# Sincroniza OVPN_USERS (fuente de verdad) con la PKI.

mgmt_cmd() {
    local sock="$OVPN_RUN_DIR/mgmt.sock"
    [[ -S $sock ]] || return 1
    # La pausa evita que socat cierre antes de recibir la respuesta.
    {
        printf '%s\n' "$1"
        sleep 1
        printf 'quit\n'
    } | socat - "UNIX-CONNECT:$sock" 2>/dev/null
}

# Desconecta sesiones activas de un usuario (si el servidor está corriendo).
kick_user() {
    mgmt_cmd "kill $1" | grep -q SUCCESS && info "Sesión activa de '$1' desconectada" || true
}

users_desired() { split_list "$OVPN_USERS"; }

users_sync() {
    pki_env
    local changed=0 user
    local -a desired
    mapfile -t desired < <(users_desired)

    if ((${#desired[@]} == 0)); then
        warn "OVPN_USERS está vacío: ningún usuario podrá conectarse"
    fi

    for user in "${desired[@]}"; do
        if pki_user_active "$user"; then
            if cert_expired "$EASYRSA_PKI/issued/$user.crt"; then
                warn "El certificado de '$user' está vencido. Renuévalo con: ovpnctl users reissue $user"
            fi
            continue
        fi
        if pki_revoked_users | grep -qxF -- "$user"; then
            warn "'$user' fue revocado previamente; no se reemite automáticamente. Usa: ovpnctl users reissue $user"
            continue
        fi
        pki_issue_client "$user"
        changed=1
    done

    if is_true "$OVPN_REVOKE_REMOVED"; then
        while read -r user; do
            [[ -z $user ]] && continue
            if ! printf '%s\n' "${desired[@]}" | grep -qxF -- "$user"; then
                pki_revoke_client "$user"
                kick_user "$user"
                changed=1
            fi
        done < <(pki_valid_users)
    fi

    ((changed)) && pki_gen_crl
    info "Usuarios activos: $(pki_valid_users | paste -sd, - || true)"
}

users_revoke() {
    pki_env
    local user=$1
    pki_user_active "$user" || die "'$user' no tiene un certificado activo"
    pki_revoke_client "$user"
    pki_gen_crl
    kick_user "$user"
    if users_desired | grep -qxF -- "$user"; then
        warn "'$user' sigue en OVPN_USERS: quítalo del .env para que la configuración sea coherente"
    fi
}

users_reissue() {
    pki_env
    local user=$1
    valid_username "$user" || die "Nombre de usuario inválido: $user"
    users_desired | grep -qxF -- "$user" || die "'$user' no está en OVPN_USERS; agrégalo primero al .env"
    if pki_user_active "$user"; then
        pki_revoke_client "$user"
        kick_user "$user"
    fi
    pki_issue_client "$user"
    pki_gen_crl
    info "Certificado de '$user' reemitido. Exporta de nuevo su perfil .ovpn"
}

users_list() {
    pki_env
    local user status expires
    printf '%-24s %-10s %-10s %s\n' USUARIO ESTADO EN_LISTA VENCE
    {
        users_desired
        pki_valid_users
        pki_revoked_users
    } | awk '!seen[$0]++' | while read -r user; do
        [[ -z $user ]] && continue
        expires="-"
        if pki_user_active "$user"; then
            expires=$(cert_expiry "$EASYRSA_PKI/issued/$user.crt")
            if cert_expired "$EASYRSA_PKI/issued/$user.crt"; then status=vencido; else status=activo; fi
        elif pki_revoked_users | grep -qxF -- "$user"; then
            status=revocado
        else
            status=pendiente
        fi
        local inlist=no
        users_desired | grep -qxF -- "$user" && inlist=si
        printf '%-24s %-10s %-10s %s\n' "$user" "$status" "$inlist" "$expires"
    done
}

# Usuarios exportables: en la lista y con certificado activo.
users_active() {
    pki_env
    local user
    while read -r user; do
        [[ -n $user ]] && pki_user_active "$user" && echo "$user"
    done < <(users_desired)
}
