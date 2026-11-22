# Configuraciones típicas

Todas las opciones se documentan en [`.env.example`](../.env.example). Tras cambiar el `.env`, ejecuta `make apply`.

## Full tunnel (por defecto)

Todo el tráfico del cliente sale por el servidor, incluido el DNS.

```dotenv
OVPN_REDIRECT_GATEWAY=true
OVPN_DNS=1.1.1.1,9.9.9.9
```

## Split tunnel: solo acceso a la LAN de casa

El cliente sigue usando su Internet normal y solo enruta tu red local por la VPN.

```dotenv
OVPN_REDIRECT_GATEWAY=false
OVPN_PUSH_ROUTES=192.168.1.0/24
OVPN_DNS=192.168.1.1        # opcional: el DNS de tu router, para nombres locales
```

> La LAN del cliente no debe usar la misma subred que la de casa (si ambas son `192.168.1.0/24` habrá conflictos). Usa en casa una subred menos común (ej. `192.168.77.0/24`).

## Full tunnel + acceso a la LAN

```dotenv
OVPN_REDIRECT_GATEWAY=true
OVPN_PUSH_ROUTES=192.168.1.0/24
```

## TCP 443 (redes que bloquean UDP)

Más lento que UDP, pero atraviesa casi cualquier firewall corporativo u hotel.

```dotenv
OVPN_PROTO=tcp
OVPN_PORT=443
```

Reenvía **TCP 443** en el router y vuelve a exportar los perfiles (`make export`).

## Sin DuckDNS (IP fija u otro DNS dinámico)

```dotenv
COMPOSE_PROFILES=
OVPN_HOSTNAME=vpn.midominio.com     # o una IP pública
```

## Usar una versión publicada de la imagen

```dotenv
OVPN_IMAGE_TAG=1.0.0
OVPN_PULL_POLICY=missing
```

`latest` o un tag no publicado hacen que la imagen se construya localmente desde `./openvpn`. Para forzar la construcción local: `OVPN_PULL_POLICY=build`.

## Comportamiento del cliente al reconectar

```dotenv
OVPN_CLIENT_PERSIST_TUN=false   # por defecto
```

- `false` (recomendado con DuckDNS): si se cae la conexión, el cliente retira las rutas de la VPN, vuelve a resolver el dominio y encuentra al servidor aunque haya cambiado de IP. Mientras tanto, su tráfico sale por la conexión normal.
- `true`: el cliente conserva la interfaz y las rutas, así que no sale tráfico fuera de la VPN durante la reconexión. Con full tunnel la consulta DNS no tiene salida: **si la IP del servidor cambia, el cliente no se recupera** hasta que lo reconectes a mano. Úsalo solo con IP fija.

Tras cambiarlo, vuelve a exportar los perfiles.

## Directivas extra

`OVPN_EXTRA_SERVER_CONFIG` añade líneas al final de `server.conf`, separadas por `|`:

```dotenv
OVPN_EXTRA_SERVER_CONFIG=max-clients 10|duplicate-cn
```

Revisa el resultado con `make config`. Úsalo con cuidado: una directiva incorrecta impide arrancar el servidor.

## Datos en un directorio del host

Por defecto la PKI vive en el volumen con nombre `ovpn-data`. Para tenerla en una carpeta visible, copia `compose.override.example.yaml` a `compose.override.yaml` y descomenta el bloque de `volumes`.
