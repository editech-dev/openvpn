# Instalación paso a paso

## 1. Preparar el host

```bash
# Docker Engine + Compose v2 (Debian/Ubuntu/Raspberry Pi OS)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # cierra sesión y vuelve a entrar
docker compose version
ls -l /dev/net/tun                # debe existir
```

Si `/dev/net/tun` no existe: `sudo modprobe tun` (y añade `tun` a `/etc/modules` para que persista).

## 2. Crear el subdominio en DuckDNS

1. Entra en <https://www.duckdns.org> e inicia sesión.
2. Crea un subdominio (ej. `mivpn` → `mivpn.duckdns.org`).
3. Copia el **token** que aparece arriba en la página. Es un secreto: no lo compartas ni lo subas a git.

> ¿Tienes IP fija u otro proveedor DNS? Deja `COMPOSE_PROFILES=` vacío y pon tu dominio o IP en `OVPN_HOSTNAME`.

## 3. Configurar

```bash
git clone https://github.com/editech-dev/openvpn.git
cd openvpn
make init
nano .env
```

Mínimo imprescindible:

```dotenv
DUCKDNS_SUBDOMAINS=mivpn
DUCKDNS_TOKEN=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
OVPN_USERS=ana-laptop,ana-movil
```

Para no tener el token en `.env`, usa Docker secrets (ver `compose.override.example.yaml`).

## 4. Abrir el puerto en el router

Crea una regla de *port forwarding*:

| Protocolo | Puerto externo | IP interna | Puerto interno |
|---|---|---|---|
| UDP | `OVPN_PORT` (1194) | IP local del host (ej. 192.168.1.10) | 1194 |

Conviene dar al host una IP fija en el DHCP del router.

Si el host tiene firewall:

```bash
sudo ufw allow 1194/udp        # ufw
# o
sudo firewall-cmd --add-port=1194/udp --permanent && sudo firewall-cmd --reload
```

## 5. Arrancar

```bash
make up
make logs
```

Debes ver, en `duckdns`, una línea indicando que la actualización fue correcta y, en `openvpn`:

```
[INFO ] Usuarios activos: ana-laptop,ana-movil
[INFO ] NAT activo: 10.8.0.0/24 -> eth0
... Initialization Sequence Completed
```

Comprueba que el dominio apunta a tu IP pública:

```bash
dig +short mivpn.duckdns.org
curl -s https://ifconfig.me
```

## 6. Exportar e importar perfiles

```bash
make export
ls -l exports/
```

Pasa cada `.ovpn` a su dispositivo por un canal seguro e impórtalo en OpenVPN Connect.

## 7. Verificar

Desde **otra red** (datos móviles, no la wifi de casa):

1. Conéctate con el perfil.
2. `make status` en el servidor debe mostrar al cliente.
3. En el cliente, <https://ifconfig.me> debe mostrar la IP pública del servidor (full tunnel).
