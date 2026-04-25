# Tello Edu Monitor

Monitor TUI + control de vuelo para el dron **DJI Tello / Tello EDU** desde la línea de comandos, implementado en Bash puro usando el protocolo **Tello SDK 2.0**.

## Descripción

`tello_monitor.sh` se conecta al dron vía WiFi y muestra un panel TUI interactivo con los principales parámetros de telemetría (batería, altitud, actitud, velocidades, temperatura y tiempo de motor) y un panel de control que permite despegar y aterrizar el dron con el teclado.

```
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     TELLO MONITOR  ·  SDK 2.0  ·  12:34:56
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Bateria   :   87%  ████████░░
  Altura    :  0 cm
  Dist. ToF :  10 cm
  Barometro : -3 cm

  Actitud   Pitch:    0  Roll:    0  Yaw:    0
  Velocidad Vx:    0  Vy:    0  Vz:    0 cm/s
  Temp      :  61 C - 63 C   Motor: 0 s

  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    CONTROL  ← → navegar  ·  Enter ejecutar  ·  q salir

      [ ↑ DESPEGAR ]       ATERRIZAR ↓

  Ultimo   :  takeoff
  Respuesta:  ok

  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Estado: actualizacion automatica cada 5s
```

## Protocolo de red (SDK 2.0)

| Dirección              | Protocolo | IP              | Puerto |
|------------------------|-----------|-----------------|--------|
| PC → Tello (comandos)  | UDP       | 192.168.10.1    | 8889   |
| Tello → PC (respuesta) | UDP       | 0.0.0.0 (bind)  | 9000   |
| Tello → PC (estado)    | UDP       | 0.0.0.0 (bind)  | 8890   |

> El puerto local **9000** se usa para enviar comandos que esperan respuesta (`takeoff`, `land`) y recibir el `ok`/`error` del Tello, siguiendo la misma convención que el SDK oficial.

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

### Controles de teclado

| Tecla       | Acción                                  |
|-------------|-----------------------------------------|
| `←` / `→`   | Navegar entre botones (DESPEGAR/ATERRIZAR) |
| `Enter`     | Ejecutar el comando seleccionado        |
| `q` / `Q`   | Salir limpiamente                       |
| `Ctrl+C`    | Salir (alternativa)                     |

Pulsa **Ctrl+C** o **q** para salir limpiamente.

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

El script realiza la inicialización en 3 pasos antes de mostrar la TUI:

1. **[1/3] Listener UDP de estado** — escucha en el puerto 8890 y guarda continuamente el último paquete de telemetría en un fichero temporal (`/tmp/tello_state_<PID>.txt`).
2. **[2/3] SDK mode** — envía el comando `command` al Tello y espera el `ok` de confirmación (bloqueante, usa puerto local 9000).
3. **[3/3] Keepalive** — envía `battery?` cada 10 segundos para evitar el aterrizaje automático por inactividad (límite del SDK: 15 s).

Una vez en la TUI:

- **Bucle de visualización** — lee el fichero de estado, extrae los campos y refresca el panel automáticamente cada 5 segundos, o inmediatamente al recibir una respuesta de comando.
- **`send_command_response`** — para `takeoff` y `land`, lanza un proceso Python3 que abre el puerto local 9000, envía el comando y espera la respuesta del Tello (timeout de 5 s). El resultado se muestra en la fila *Respuesta* de la TUI.
- **Limpieza** — al salir (Ctrl+C, señal TERM o tecla `q`) se restaura el estado original del terminal, se matan los procesos de fondo y se eliminan los ficheros temporales.

## Estructura del proyecto

```
03. Tello_Edu_Monitor/
└── tello_monitor.sh    # Script principal
```

## Notas

- El script permite **despegar** (`takeoff`) y **aterrizar** (`land`) el dron desde el panel de control TUI.
- El Tello transmite el estado a ~10-20 Hz de forma continua una vez que recibe el comando `command`.

## Referencia

- [Tello SDK 2.0 User Guide](https://dl-cdn.ryzerobotics.com/downloads/Tello/Tello%20SDK%202.0%20User%20Guide.pdf)
