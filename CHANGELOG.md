# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y [SemVer](https://semver.org/lang/es/).

## [Sin publicar]

### Añadido
- Imagen OpenVPN propia (Alpine 3.24, OpenVPN 2.7, easy-rsa 3.2) con PKI automática EC P-256 y `tls-crypt`.
- Lista de usuarios permitidos (`OVPN_USERS`) con alta y revocación automáticas.
- CLI `ovpnctl`: `users list|active|sync|revoke|reissue`, `export`, `status`, `config`.
- Scripts del host: `export-clients.sh`, `ovpn.sh`, `backup-pki.sh`.
- Servicio DuckDNS opcional (perfil de Compose).
- Contenedor endurecido (read-only, `cap_drop: ALL`, `no-new-privileges`, OpenVPN como `nobody`), soporte DCO.
- Pruebas unitarias (bats) y prueba end-to-end con cliente real.
- CI (lint, gitleaks, tests, Trivy) y release multi-arquitectura a GHCR con SBOM y firma cosign.
