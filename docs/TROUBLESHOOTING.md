# Solución de problemas

Empieza siempre por: `make ps`, `make logs` y `make config`.

## El contenedor `openvpn` se reinicia en bucle

Mira el primer `[ERROR]` en `docker compose logs openvpn`:

| Mensaje | Causa / solución |
|---|---|
| `Usuario inválido en OVPN_USERS` | Nombre con espacios, tildes o símbolos. Usa `[A-Za-z0-9_.-]`. |
| `OVPN_NETWORK debe ser un CIDR…` | Formato `10.8.0.0/24`, prefijo entre /16 y /29. |
| `/dev/net/tun no disponible` | `sudo modprobe tun` en el host. |
| `Options error` | Suele venir de `OVPN_EXTRA_SERVER_CONFIG`. Vacíalo y vuelve a probar. |

## El cliente no conecta (`TLS handshake failed`, timeout)

1. ¿El dominio resuelve a tu IP pública? `dig +short <subdominio>.duckdns.org` y `curl -s https://ifconfig.me`.
2. ¿El puerto está reenviado en el router y el protocolo coincide (UDP/TCP)?
3. ¿Pruebas desde fuera? Muchos routers no soportan *NAT loopback*: conectarte desde tu propia wifi al dominio público puede fallar aunque todo esté bien. Prueba con datos móviles.
4. **CG-NAT:** si la IP WAN de tu router (en su panel) es distinta de `ifconfig.me`, o empieza por `100.64.`–`100.127.`, tu proveedor usa CG-NAT y no puedes recibir conexiones entrantes. Pide una IP pública a tu ISP o usa un VPS como punto de entrada.
5. ¿El perfil es actual? Si cambiaste `OVPN_HOSTNAME`, `OVPN_PORT`, `OVPN_PROTO` o reemitiste el usuario, vuelve a exportarlo.

## El cliente se queda en `RESOLVE: Cannot resolve host address`

El cliente no puede resolver el dominio mientras reconecta. Si el perfil contiene `persist-tun` (perfiles antiguos o `OVPN_CLIENT_PERSIST_TUN=true`), las rutas del túnel caído capturan el DNS. Vuelve a exportar el perfil con `OVPN_CLIENT_PERSIST_TUN=false` (valor por defecto).

## VM en la nube: no conecta nadie

El firewall del proveedor bloquea el puerto. En Google Cloud crea la regla para UDP 1194 y la etiqueta de red en la VM (ver [DEPLOY-CLOUD.md](DEPLOY-CLOUD.md)). Comprueba también que `docker compose ps` muestra `0.0.0.0:1194->1194/udp`.

## `VERIFY ERROR … certificate revoked`

El usuario está revocado. Si debe tener acceso: añádelo a `OVPN_USERS` y ejecuta `./scripts/ovpn.sh users reissue <usuario>`.

## Conecta pero no hay Internet

- En el host: `sysctl net.ipv4.ip_forward` dentro del contenedor debe ser `1` (lo fija `compose.yaml`).
- Si el host usa un firewall que bloquea el reenvío de Docker (ej. reglas `DOCKER-USER`), permite el tráfico del contenedor.
- `OVPN_NETWORK` no debe solaparse con la red de Docker ni con la LAN del cliente.
- Prueba otro DNS en `OVPN_DNS`.

## DuckDNS no actualiza

- `docker compose logs duckdns`: un `KO` indica token o subdominio incorrectos.
- `DUCKDNS_SUBDOMAINS` va **sin** `.duckdns.org`.
- Comprueba que `COMPOSE_PROFILES` contiene `duckdns`.

## Exportar falla con "no tiene un certificado activo"

El usuario no está en `OVPN_USERS` o falta `make apply`. Revisa con `make users`.
