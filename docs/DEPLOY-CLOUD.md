# Despliegue en una VM en la nube (ejemplo: Google Cloud)

Guía probada de principio a fin en una VM **e2-micro / Debian 13** (2 vCPU compartidas, 1 GB de RAM). El consumo real es mínimo: unos 2–3 MB de RAM por contenedor y CPU prácticamente nula en reposo.

Los valores entre `<...>` son tuyos; **no los subas nunca a git**.

| Marcador | Ejemplo |
|---|---|
| `<PROYECTO>` | ID del proyecto de Google Cloud |
| `<VM>` | nombre de la instancia |
| `<USUARIO>` | tu usuario SSH en la VM |
| `<IP_VM>` | IP externa de la VM |
| `<LLAVE_SSH>` | ruta a tu llave privada SSH |
| `<SUBDOMINIO>` | tu subdominio de DuckDNS, sin `.duckdns.org` |

---

## 1. Abrir el puerto en el firewall de la nube

En Google Cloud el tráfico entrante está bloqueado por defecto. Crea una regla para el puerto VPN y aplícala a la VM con una **etiqueta de red**:

```bash
gcloud compute firewall-rules create allow-openvpn \
  --project=<PROYECTO> --network=default --direction=INGRESS \
  --allow=udp:1194 --target-tags=openvpn --source-ranges=0.0.0.0/0

gcloud compute instances add-tags <VM> --tags=openvpn --zone=<ZONA> --project=<PROYECTO>
```

O desde la consola: **VPC network → Firewall → Create firewall rule** (UDP 1194, *target tags* `openvpn`) y añade la etiqueta `openvpn` a la VM en **Editar → Etiquetas de red**.

> Si usas `OVPN_PROTO=tcp` u otro puerto, ajusta la regla.

## 2. Instalar Docker en la VM (Debian)

Repositorio APT oficial de Docker, sin ejecutar scripts descargados:

```bash
ssh -i <LLAVE_SSH> <USUARIO>@<IP_VM>

sudo apt-get update
sudo apt-get install -y ca-certificates curl make
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"     # cierra la sesión SSH y vuelve a entrar
docker compose version
```

`make` es opcional: todos los comandos tienen su equivalente en `scripts/` (ver README).

## 3. Desplegar

```bash
git clone https://github.com/editech-dev/openvpn.git
cd openvpn
cp .env.example .env && chmod 600 .env
nano .env        # DUCKDNS_SUBDOMAINS, DUCKDNS_TOKEN, OVPN_USERS
docker compose up -d
docker compose logs -f     # espera "Initialization Sequence Completed" y "DuckDNS request ... successful"
```

La primera vez construye la imagen (unos 20 s) si no hay una versión publicada.

## 4. Exportar los perfiles a tu equipo

```bash
# en la VM
./scripts/export-clients.sh

# en tu equipo
mkdir -p exports && chmod 700 exports
scp -i <LLAVE_SSH> '<USUARIO>@<IP_VM>:openvpn/exports/*.ovpn' exports/
chmod 600 exports/*.ovpn
```

Borra los perfiles de la VM cuando ya los tengas: `rm -rf ~/openvpn/exports`.

## 5. Verificar desde fuera

```bash
dig +short <SUBDOMINIO>.duckdns.org      # debe devolver <IP_VM>
```

Conéctate con un perfil desde **otra red** y comprueba en <https://ifconfig.me> que tu IP pública es `<IP_VM>`. En la VM, `./scripts/ovpn.sh status` lista los clientes conectados.

## 6. Backup fuera de la VM

La PKI es lo único irrecuperable. Guarda una copia en tu equipo:

```bash
# en la VM
./scripts/backup-pki.sh backup
# en tu equipo
scp -i <LLAVE_SSH> '<USUARIO>@<IP_VM>:openvpn/backups/*' backups/ && chmod 600 backups/*
```

---

## IP externa: efímera o reservada

- Una IP **efímera** se conserva al reiniciar el sistema operativo o al hacer *Reset*. Puede cambiar al **detener e iniciar** la VM, aunque no siempre ocurre.
- **No hace falta reservar una IP estática**: los perfiles usan el dominio de DuckDNS. Si la IP cambia, el contenedor `duckdns` la publica al arrancar y luego cada 5 minutos, y los clientes vuelven a resolver el dominio y reconectan solos.
- Reservar una IP estática evita esos minutos de espera, pero puede tener coste.

## Comportamiento ante caídas (verificado)

| Evento | Resultado |
|---|---|
| Reinicio del contenedor (`docker compose restart openvpn`) | Apagado limpio en ~3 s; clientes reconectados en ~11 s |
| Caída del servidor > 60 s | Los clientes reintentan cada ≤30 s y reconectan ~3 s después de que vuelve |
| Reinicio de la VM / detener e iniciar | Docker y los servicios arrancan solos; clientes reconectados ~15 s después |
| Cambio de IP del servidor | DuckDNS se actualiza al arrancar; si la IP anterior no responde en 10 s, el cliente re-resuelve el dominio y reconecta (~15 s en pruebas) |

Mientras el servidor está caído, el cliente retira las rutas de la VPN para poder volver a resolver el dominio. Durante ese intervalo el tráfico sale por la conexión normal del cliente. Si prefieres bloquearlo, consulta `OVPN_CLIENT_PERSIST_TUN` en [CONFIG.md](CONFIG.md).

## Endurecimiento recomendado de la VM

- Deja abiertos en el firewall de la nube solo SSH (idealmente limitado a tu IP o vía IAP) y el puerto VPN.
- Actualizaciones automáticas: `sudo apt install unattended-upgrades`.
- Usa llaves SSH, no contraseñas.
