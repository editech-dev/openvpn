# Seguridad

## Reportar una vulnerabilidad

No abras un issue público. Usa **[Report a vulnerability](https://github.com/editech-dev/openvpn/security/advisories/new)** (GitHub Security Advisories). Se responderá lo antes posible.

## Modelo de amenazas y decisiones

| Riesgo | Mitigación |
|---|---|
| Escaneo / DoS sobre el puerto VPN | `tls-crypt`: los paquetes sin la llave compartida se descartan antes del handshake TLS. |
| Robo de un perfil `.ovpn` | Un certificado por usuario y dispositivo; `users revoke` lo invalida y corta la sesión. |
| Ataques criptográficos | TLS ≥ 1.2, AEAD, EC P-256, sin compresión (evita VORACLE). |
| Compromiso del proceso OpenVPN | Corre como `nobody`; contenedor `read_only`, `no-new-privileges`, capacidades mínimas. |
| Imágenes con CVE | Base fijada por digest + Dependabot + Trivy en CI. |
| Secretos en git | `.gitignore` + gitleaks (CI y pre-commit). |

## Limitaciones conocidas

- Las llaves de la CA y de los clientes **no tienen passphrase**, para permitir la emisión y revocación automáticas. Quien tenga acceso al volumen `ovpn-data` (o a un backup sin cifrar) puede emitir certificados. Protege el host y cifra los backups.
- La CRL se regenera en cada cambio con 10 años de vigencia; se renueva en cada arranque.
- No se gestiona IPv6 dentro del túnel. En full tunnel, un cliente con IPv6 podría enviar ese tráfico fuera de la VPN; desactiva IPv6 en el cliente si te importa.

## Recomendaciones para producción

- Mantén el host actualizado y con firewall (solo el puerto VPN y SSH expuestos).
- Un usuario por dispositivo; revisa `make users` periódicamente y da de baja lo que no se use.
- Backups cifrados (`--age-recipient`) y fuera del servidor.
- Fija `OVPN_IMAGE_TAG` a una versión concreta y actualiza conscientemente.
- Verifica la firma de la imagen:

  ```bash
  cosign verify ghcr.io/editech-dev/openvpn:1.0.0 \
    --certificate-identity-regexp 'https://github.com/editech-dev/openvpn/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```
