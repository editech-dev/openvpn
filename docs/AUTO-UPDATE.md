# Actualización automática, vigilancia y avisos

El servidor se mantiene al día **por sí solo, sin depender de GitHub** ni de imágenes de terceros. Si algo sale mal, vuelve a la versión anterior y te avisa por **Telegram**.

| Qué | Cómo | Cuándo |
|---|---|---|
| Imagen `openvpn` + `duckdns` | Se reconstruye **en el propio servidor** con los últimos parches de Alpine. Solo se despliega si hay paquetes nuevos y luego se verifica. | A diario (configurable) |
| Sistema operativo | `unattended-upgrades` de Debian, ampliado para incluir Docker y reiniciar si un parche lo requiere (kernel, libc…). | A diario |
| Vigilancia | Comprueba que los servicios están sanos y avisa en cada cambio de estado. | Cada 10 min y al arrancar |

Todo se instala con un único comando: `sudo ./scripts/install-host.sh`.

---

## 1. Cómo funciona la actualización

```mermaid
flowchart TD
    T[Timer diario] --> F{¿Congelado?}
    F -- sí --> R[No hace nada<br/>recordatorio semanal]
    F -- no --> B[Construye imagen candidata<br/>con apk upgrade]
    B -- falla la construcción --> W[Aviso ⚠️<br/>sigue la versión actual]
    B --> C{¿Paquetes distintos?}
    C -- no --> N[Fin: no se reinicia nada]
    C -- sí --> D[Guarda la actual como :rollback<br/>despliega la candidata]
    D --> V{¿openvpn y duckdns sanos<br/>en ≤150 s?}
    V -- sí --> OK[Aviso ✅ con los paquetes nuevos]
    V -- no --> RB[Vuelve a :rollback<br/>y verifica]
    RB --> Z[CONGELA las actualizaciones<br/>y avisa 🚨 con los logs]
```

- **Sin GitHub:** la imagen se construye a partir de `openvpn/Dockerfile` con los paquetes oficiales de Alpine. Solo hace falta acceso a `dl-cdn.alpinelinux.org`, y a Docker Hub únicamente si cambia la imagen base.
- **Detección de cambios:** cada imagen guarda su lista de paquetes en `/usr/local/share/ovpn/packages.txt`. Si la candidata trae exactamente los mismos paquetes, se descarta y **no se reinicia nada**.
- **Despliegue:** se recrean ambos contenedores. Los clientes VPN reconectan solos en unos 10–15 s, y la PKI y los usuarios no se tocan.
- **Verificación:** ambos servicios deben pasar su *healthcheck* con la imagen nueva y `ovpnctl` debe responder.
- **Vuelta atrás y congelado:** si la verificación falla, se restaura la versión anterior (`…:latest-rollback`) y se crea `.state/frozen`. Mientras exista ese archivo, no se vuelve a intentar: así **se queda en la versión que funciona** hasta que lo revises. Cada semana llega un recordatorio.
- **Versiones mayores** (por ejemplo, Alpine 3.24 → 3.25) **no** se aplican solas: requieren cambiar el `FROM` del Dockerfile a mano y probarlo.

### Frecuencia: ¿por qué a diario?

Revisar cuesta menos de un minuto de CPU y unos pocos MB de descarga. En la nube ese tráfico es de entrada y no se suele cobrar. **Solo se reinicia algo cuando hay parches**, lo que en la práctica ocurre pocas veces al mes. Alpine publica correcciones de seguridad sin calendario fijo, así que una revisión semanal dejaría hasta 7 días de exposición.

Si prefieres otra frecuencia, cambia `AUTOUPDATE_ONCALENDAR` y vuelve a ejecutar `sudo ./scripts/install-host.sh`:

```dotenv
AUTOUPDATE_ONCALENDAR=*-*-* 04:00:00 Europe/Madrid    # diario a las 04:00 hora local
AUTOUPDATE_ONCALENDAR=Sun *-*-* 04:00:00 UTC          # semanal (domingos)
AUTOUPDATE_ONCALENDAR=*-*-01 04:00:00 UTC             # mensual
```

Comprueba una expresión con `systemd-analyze calendar "<expresión>"`.

---

## 2. Configurar los avisos de Telegram

1. En Telegram, abre **@BotFather** y envía `/newbot`. Elige un nombre y un usuario para el bot. BotFather te dará un **token** del estilo `123456789:AA…`.
2. Abre el chat con tu bot nuevo y envíale cualquier mensaje (por ejemplo `/start`). Si no lo haces, el bot no puede escribirte.
3. Obtén tu **chat_id** desde el servidor. El token no aparece en el historial de la shell porque se lee con `read -s`:
   ```bash
   read -rs TOKEN && curl -s "https://api.telegram.org/bot${TOKEN}/getUpdates" | grep -o '"chat":{"id":-\?[0-9]*' ; unset TOKEN
   ```
   El número que aparece tras `"id":` es tu `chat_id`.
4. Añade ambos valores al `.env` (que tiene permisos 600 y nunca se sube a git):
   ```dotenv
   NOTIFY_TELEGRAM_TOKEN=123456789:AA...
   NOTIFY_TELEGRAM_CHAT_ID=987654321
   ```
5. Prueba: `make notify-test` (o `./scripts/notify.sh --test`). El mensaje debe llegarte al móvil.

Cada aviso empieza con el nombre de la instancia (`[mivpn.duckdns.org]`) para distinguir servidores si tienes varios.

### Qué avisos llegan

| Aviso | Cuándo |
|---|---|
| ✅ Actualización aplicada y verificada (con la lista de paquetes) | Tras un despliegue correcto. Se desactiva con `NOTIFY_ON_SUCCESS=false`. |
| 🚨 Falló la actualización… CONGELADAS | La versión nueva no quedó sana. Incluye el motivo, el resultado de la vuelta atrás y los últimos logs. |
| ❌ CRÍTICO: la versión anterior TAMPOCO quedó sana | También falló la vuelta atrás. Hay que entrar al servidor. |
| ⚠️ No se pudo construir la imagen | Sin acceso a los repositorios, por ejemplo. No se cambia nada y se reintenta al día siguiente. |
| ⏸️ Recordatorio: siguen congeladas | Una vez por semana mientras sigan congeladas. |
| ⚠️ `servicio` no está sano / ✅ se recuperó | Lo envía el vigilante; solo avisa en los cambios de estado, sin repetir. |
| ⚠️ Docker no responde | El vigilante no puede consultar Docker. |
| 🔄 El servidor arrancó | En cada arranque, por ejemplo tras un reinicio automático por kernel. |

### ¿Y si el servidor se apaga del todo?

Un servidor apagado no puede avisar. Para cubrir ese caso, crea un *check* gratuito en [healthchecks.io](https://healthchecks.io) con un periodo de 10 minutos, conéctalo a tu Telegram desde su panel y pon su URL en el `.env`:

```dotenv
NOTIFY_HEARTBEAT_URL=https://hc-ping.com/<uuid>
```

El vigilante envía un latido cada 10 minutos, a `/fail` si algún servicio no está sano. Si deja de llegar, healthchecks.io te avisa.

---

## 3. Instalar en el servidor

Requisitos: el usuario pertenece al grupo `docker`, existe el `.env` y está instalado `unattended-upgrades` (viene por defecto en Debian/Ubuntu de la nube).

```bash
cd ~/openvpn
sudo ./scripts/install-host.sh      # idempotente: vuelve a ejecutarlo tras cambiar AUTOUPDATE_*
```

Instala, con el usuario que invoca `sudo` (no como root):

| Unidad | Función |
|---|---|
| `openvpn-autoupdate.timer` / `.service` | Ejecuta `scripts/auto-update.sh` según `AUTOUPDATE_ONCALENDAR`. Tiene `Persistent=true`: si el servidor estaba apagado a esa hora, se ejecuta al arrancar. |
| `openvpn-watchdog.timer` / `.service` | Ejecuta `scripts/watchdog.sh` cada `WATCHDOG_INTERVAL`. |
| `openvpn-boot-notify.service` | Envía el aviso de arranque. |
| `openvpn-notify-failure@.service` | Avisa si alguna de las anteriores termina con un error inesperado. |
| `/etc/apt/apt.conf.d/52openvpn-unattended` | Incluye el repositorio de Docker en las actualizaciones del SO y activa el reinicio automático a `AUTOUPDATE_REBOOT_TIME` (hora del sistema) solo cuando un parche lo requiere. Se omite con `AUTOUPDATE_OS=false`. |

Comprobaciones:

```bash
systemctl list-timers 'openvpn-*'
sudo unattended-upgrade --dry-run -d 2>&1 | grep -i 'allowed origins'   # debe incluir Docker
journalctl -u openvpn-autoupdate -n 50                                  # historial
```

Desinstalar (no toca contenedores, PKI ni `.env`): `sudo ./scripts/install-host.sh --uninstall`.

> **Hora del reinicio:** `AUTOUPDATE_REBOOT_TIME` usa la zona del sistema, normalmente UTC en la nube. Elige una hora posterior a la de `AUTOUPDATE_ONCALENDAR` y de poco uso.

---

## 4. Operación del día a día

| Quiero… | Comando |
|---|---|
| Ver el estado (¿congelado?, última ejecución, imágenes) | `make update-status` |
| Actualizar ahora | `make update` |
| Ver qué paquetes cambiarían, sin desplegar | `./scripts/auto-update.sh --dry-run` |
| Forzar un despliegue aunque no haya paquetes nuevos | `./scripts/auto-update.sh --force` |
| Probar la vuelta atrás y el aviso de fallo | `./scripts/auto-update.sh --simulate-failure` |
| Reanudar tras revisar un fallo | `make update-unfreeze` |
| Pausar las actualizaciones | `AUTOUPDATE_ENABLED=false` en `.env` |
| Aplicar un cambio de **código** del repo (tras `git pull`) | `make build && make up` |

### Tras un aviso de fallo 🚨

1. La VPN sigue funcionando con la versión anterior. No hay urgencia, salvo que el aviso diga **CRÍTICO**.
2. Revisa qué pasó:
   ```bash
   make update-status
   journalctl -u openvpn-autoupdate -n 100
   docker image ls ghcr.io/editech-dev/openvpn   # la candidata fallida queda como :latest-failed
   ```
3. Prueba de nuevo, quizá ya con el parche corregido: `make update-unfreeze && ./scripts/auto-update.sh --force`.
4. Si el problema persiste, mantén el congelado hasta que salga una versión corregida de Alpine. Borra `:latest-failed` cuando ya no lo necesites: `docker rmi ghcr.io/editech-dev/openvpn:latest-failed`.

---

## 5. Variables

| Variable | Por defecto | Descripción |
|---|---|---|
| `NOTIFY_TELEGRAM_TOKEN` | — | Token del bot (**secreto**). Vacío = sin avisos; quedan solo en el journal. |
| `NOTIFY_TELEGRAM_CHAT_ID` | — | Chat al que se envían los avisos. |
| `NOTIFY_ON_SUCCESS` | `true` | Avisar también de las actualizaciones correctas. |
| `NOTIFY_HEARTBEAT_URL` | — | URL de latido (healthchecks.io u otro compatible), solo `https`. |
| `AUTOUPDATE_ENABLED` | `true` | `false` = el timer no hace nada. Las ejecuciones manuales con opción siguen funcionando. |
| `AUTOUPDATE_ONCALENDAR` | `*-*-* 04:00:00 UTC` | Cuándo revisar parches (formato `OnCalendar` de systemd). Se aplica un retraso aleatorio de hasta 15 min. |
| `AUTOUPDATE_VERIFY_TIMEOUT` | `150` | Segundos para que la versión nueva quede sana. |
| `AUTOUPDATE_OS` | `true` | Configurar `unattended-upgrades` (Docker y reinicio automático). |
| `AUTOUPDATE_REBOOT_TIME` | `05:30` | Hora (del sistema) del reinicio automático, solo si un parche lo requiere. |
| `WATCHDOG_INTERVAL` | `10min` | Frecuencia del vigilante. |

Estas variables solo las leen los scripts del host: Compose **no** las pasa a los contenedores.

> La actualización automática trabaja con la imagen construida localmente (`OVPN_PULL_POLICY=missing`, el valor por defecto). Si usas imágenes publicadas con `OVPN_PULL_POLICY=always`, el actualizador se niega a ejecutarse para no mezclar ambos modelos.

---

## 6. Seguridad

- Los tokens de Telegram y DuckDNS se pasan a `curl` por la entrada estándar: **no aparecen en la lista de procesos ni en los logs**.
- Los timers corren con tu usuario (grupo `docker`), no como root. Solo `install-host.sh` necesita `sudo`.
- `.state/` (estado del actualizador, permisos 700) está en `.gitignore`.
- Los avisos de fallo incluyen las últimas líneas de log, que pueden contener nombres de usuario o IPs de clientes. Llegan solo a tu chat privado con el bot.
