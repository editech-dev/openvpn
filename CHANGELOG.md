# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y [SemVer](https://semver.org/lang/es/).

## [Sin publicar]

### Corregido
- **Las revocaciones no surtían efecto hasta reiniciar el servidor**: la CRL vivía en `/etc/openvpn` (0700 root) y OpenVPN, ya como `nobody`, no podía releerla (`Failed to stat CRL file`). Ahora se publica en `/run/openvpn/crl.pem`, legible por `nobody`, y un usuario revocado queda rechazado al instante. La prueba end-to-end comprueba que un perfil revocado no reconecta sin reiniciar.

### Añadido
- **Actualización automática sin GitHub** (`scripts/auto-update.sh`): reconstruye la imagen en el host con los parches de Alpine y solo la despliega si hay paquetes nuevos. Verifica que los servicios quedan sanos y, si no, vuelve a la versión anterior, congela las actualizaciones y avisa.
- **Avisos por Telegram** (`scripts/notify.sh`, admite chat, grupo o canal): solo se publican dos mensajes, "✅ Nueva versión instalada correctamente" y "🚨 Error al actualizar", ambos con la versión anterior → nueva y los paquetes o el error.
- **Vigilante** (`scripts/watchdog.sh`): registra en el journal las caídas y recuperaciones de los servicios y los arranques (publicarlos es opcional con `NOTIFY_WATCHDOG=true`), y envía un latido opcional a healthchecks.io.
- `scripts/install-host.sh`: timers de systemd y `unattended-upgrades` ampliado (Docker y reinicio automático cuando hace falta).
- Prueba automática de la actualización, la vuelta atrás, el congelado, el vigilante y los avisos (`tests/autoupdate.sh`), incluida en CI.

### Cambiado
- **DuckDNS ahora usa la misma imagen del proyecto** (modo `duckdns`) en lugar de `linuxserver/duckdns`: sin imágenes de terceros, corre como `nobody` sin capacidades y con el token oculto de la lista de procesos. Variables nuevas: `DUCKDNS_INTERVAL` y `DUCKDNS_TOKEN_FILE`. Se retiran `DUCKDNS_UPDATE_IP` (solo IPv4), `PUID` y `PGID`.
- La imagen aplica `apk upgrade` al construirse y guarda su lista de paquetes.
- Se retira Dependabot: los parches se aplican en el propio servidor y el repositorio mantiene una sola rama.
- Imagen OpenVPN propia (Alpine 3.24, OpenVPN 2.7, easy-rsa 3.2) con PKI automática EC P-256 y `tls-crypt`.
- Lista de usuarios permitidos (`OVPN_USERS`) con alta y revocación automáticas.
- CLI `ovpnctl`: `users list|active|sync|revoke|reissue`, `export`, `status`, `config`.
- Scripts del host: `export-clients.sh`, `ovpn.sh`, `backup-pki.sh`.
- Servicio DuckDNS opcional (perfil de Compose).
- Contenedor endurecido (read-only, `cap_drop: ALL`, `no-new-privileges`, OpenVPN como `nobody`), soporte DCO.
- Pruebas unitarias (bats) y prueba end-to-end con cliente real.
- CI (lint, gitleaks, tests, Trivy) y release multi-arquitectura a GHCR con SBOM y firma cosign.
- `OVPN_CLIENT_PERSIST_TUN` para elegir el comportamiento del cliente al reconectar.
- Guía de despliegue en la nube (`docs/DEPLOY-CLOUD.md`), validada en una VM real.

### Corregido (encontrado en pruebas de despliegue real)
- El backup quedaba corrupto si Compose construía la imagen durante el `run`; ahora se valida antes de guardar y de restaurar.
- `grep -q` con `pipefail` provocaba falsos negativos (riesgo de reemitir certificados).
- `block-outside-dns` se enviaba a todos los clientes y producía `Options error` fuera de Windows.
- tini no podía reenviar `SIGTERM` a OpenVPN (faltaba `CAP_KILL`): apagado forzado y clientes ~2 min sin servicio.
- Tras un reinicio del servidor el cliente insistía 60 s en la IP anterior antes de re-resolver el dominio; ahora `server-poll-timeout 10` (cambio de IP: de ~67 s a ~15 s).
- Con `persist-tun` en el perfil, un cliente en full tunnel no podía re-resolver el dominio y quedaba colgado tras una caída o un cambio de IP.
