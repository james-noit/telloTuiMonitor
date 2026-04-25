# Tello Edu Monitor

Monitor de estado en tiempo real para el dron **DJI Tello / Tello EDU** desde la línea de comandos, implementado en Bash puro usando el protocolo **Tello SDK 2.0**.

## Descripción

`tello_monitor.sh` se conecta al dron vía WiFi y muestra un panel actualizable con los principales parámetros de telemetría: batería, altitud, actitud (pitch/roll/yaw), velocidades, temperatura y tiempo de motor.

```
  ╔═══════════════════════════════════════╗
  ║  TELLO MONITOR  —  12:34:56          ║
  ╚═══════════════════════════════════════╝

  Batería:          87%
  Altura:           0 cm
  Dist. ToF:        10 cm
  Barómetro:        -3 cm

  Actitud
    Pitch: 0°    Roll: 0°    Yaw: 0°

  Velocidad (cm/s)
    Vx: 0    Vy: 0    Vz: 0

  Temperatura:      61°C – 63°C
  Tiempo motor:     0 s

  Actualización: cada 5s  |  Ctrl+C para salir
```

## Protocolo de red (SDK 2.0)

| Dirección        | Protocolo | IP              | Puerto |
|------------------|-----------|-----------------|--------|
| PC → Tello       | UDP       | 192.168.10.1    | 8889   |
| Tello → PC       | UDP       | 0.0.0.0 (bind)  | 8890   |

## Requisitos

- **Bash** 4.0 o superior (disponible en Linux y macOS con Homebrew)
- Conexión a la red WiFi del Tello (`TELLO-XXXXXX`)
- Una de las siguientes herramientas para recibir UDP:
  - `socat` *(recomendado)*
  - `python3` *(alternativa fiable)*
  - `nc` / netcat *(último recurso)*

### Instalar socat

```bash
# Debian / Ubuntu
sudo apt install socat

# Arch Linux
sudo pacman -S socat

# macOS
brew install socat
```

## Uso

```bash
# Conectarse primero a la red WiFi del Tello (TELLO-XXXXXX)

chmod +x tello_monitor.sh
./tello_monitor.sh
```

Pulsa **Ctrl+C** para salir limpiamente.

## Parámetros monitorizados

| Campo        | Descripción                        | Unidad |
|--------------|------------------------------------|--------|
| `bat`        | Nivel de batería                   | %      |
| `h`          | Altura estimada (IMU)              | cm     |
| `tof`        | Distancia sensor ToF               | cm     |
| `baro`       | Altitud barométrica relativa       | cm     |
| `pitch`      | Ángulo de cabeceo                  | °      |
| `roll`       | Ángulo de balanceo                 | °      |
| `yaw`        | Ángulo de guiñada                  | °      |
| `vgx/vgy/vgz`| Velocidad en ejes X, Y, Z         | cm/s   |
| `templ/temph`| Temperatura mínima / máxima IMU    | °C     |
| `time`       | Tiempo acumulado de motor encendido| s      |

## Funcionamiento interno

1. **Listener UDP** — escucha en el puerto 8890 y guarda continuamente el último paquete de estado en un fichero temporal (`/tmp/tello_state_<PID>.txt`).
2. **Keepalive** — envía `battery?` cada 10 segundos para evitar el aterrizaje automático por inactividad (límite del SDK: 15 s).
3. **Bucle de visualización** — lee el fichero de estado, extrae los campos y refresca el panel cada 5 segundos.

## Estructura del proyecto

```
03. Tello_Edu_Monitor/
└── tello_monitor.sh    # Script principal
```

## Notas

- El script **no hace despegar ni aterrizar** el dron; solo monitoriza su estado.
- El Tello transmite el estado a ~10-20 Hz de forma continua una vez que recibe el comando `command`.
- El fichero temporal se elimina automáticamente al salir (Ctrl+C o señal TERM).

## Referencia

- [Tello SDK 2.0 User Guide](https://dl-cdn.ryzerobotics.com/downloads/Tello/Tello%20SDK%202.0%20User%20Guide.pdf)
