# Tello Edu Monitor

Monitor TUI + control de vuelo para el dron **DJI Tello / Tello EDU** desde la línea de comandos, implementado en Bash puro usando el protocolo **Tello SDK 2.0**.

## Descripción

`tello_monitor.sh` se conecta al dron vía WiFi y muestra un panel TUI interactivo con los principales parámetros de telemetría (batería, altitud, actitud, velocidades, temperatura y tiempo de motor) y un panel de control con **selector de comandos SDK 2.0**. Incluye comandos sin argumentos (`command`, `takeoff`, `land`, `streamon`, `streamoff`, `emergency`) y comandos con parámetro `x` (`up/down/left/right/forward/back/cw/ccw`) con validación de rango según el SDK.

```text
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
    CONTROL  ← → mover  ·  ↑ ↓ cambiar bloque  ·  Enter ejecutar  ·  q salir

    Comandos base
    CONNECT      TAKEOFF      LAND         STREAM ON     STREAM OFF    [ EMERGENCY ]

    Movimiento y rotacion
    UP x         DOWN x       LEFT x       RIGHT x       FWD x         BACK x       CW x         CCW x

    Seleccion: [6/14] EMERGENCY
    Comando: emergency
    Parametro: sin argumentos

  ┌─ Respuesta del dron ──────────────────────────┐
  │  Comando  :  takeoff                          │
  │  Resultado:  ok                               │
  └───────────────────────────────────────────────┘

  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Estado: actualizacion automatica cada 5s
```

## Protocolo de red (SDK 2.0)

| Dirección              | Protocolo | IP              | Puerto |
|------------------------|-----------|-----------------|--------|
| PC → Tello (comandos)  | UDP       | 192.168.10.1    | 8889   |
| Tello → PC (respuesta) | UDP       | 0.0.0.0 (bind)  | 9000   |
| Tello → PC (estado)    | UDP       | 0.0.0.0 (bind)  | 8890   |

Nota: el script usa el puerto local **9000** para comandos que esperan respuesta (por ejemplo `command`, `takeoff`, `streamon`, `up 50`, `cw 90`, etc.). El listener de estado escucha en el puerto `8890` y guarda el último paquete junto con un timestamp para detectar pérdida de señal.

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

- `←` / `→`: mover selección dentro del bloque.
- `↑` / `↓`: cambiar entre bloque base y bloque de movimiento.
- `Enter`: ejecutar el comando seleccionado.
- `c` / `C`: cancelar el prompt de argumento `x`.
- `q` / `Q`: salir limpiamente.
- `Ctrl+C`: salir (alternativa).

Pulsa **Ctrl+C** o **q** para salir limpiamente.

## Comandos de control implementados

| Comando SDK | Requiere argumento | Rango válido |
|-------------|--------------------|--------------|
| `command`   | No                 | -            |
| `takeoff`   | No                 | -            |
| `land`      | No                 | -            |
| `streamon`  | No                 | -            |
| `streamoff` | No                 | -            |
| `emergency` | No                 | -            |
| `up x`      | Sí (`x`)           | `20-500` cm  |
| `down x`    | Sí (`x`)           | `20-500` cm  |
| `left x`    | Sí (`x`)           | `20-500` cm  |
| `right x`   | Sí (`x`)           | `20-500` cm  |
| `forward x` | Sí (`x`)           | `20-500` cm  |
| `back x`    | Sí (`x`)           | `20-500` cm  |
| `cw x`      | Sí (`x`)           | `1-360`°     |
| `ccw x`     | Sí (`x`)           | `1-360`°     |

## Parámetros monitorizados

- `bat`: nivel de batería (%).
- `h`: altura estimada por IMU (cm).
- `tof`: distancia medida por sensor ToF (cm).
- `baro`: altitud barométrica relativa (cm).
- `pitch`: ángulo de cabeceo (°).
- `roll`: ángulo de balanceo (°).
- `yaw`: ángulo de guiñada (°).
- `vgx/vgy/vgz`: velocidad en ejes X, Y, Z (cm/s).
- `templ/temph`: temperatura mínima y máxima IMU (°C).
- `time`: tiempo acumulado de motor encendido (s).

## Funcionamiento interno

Cambios importantes en la versión actual del script:

1. **Inicio mínimo** — al arrancar el script se inicia **solo** el listener de estado (puerto 8890) y el keepalive; no se activa automáticamente el SDK mode. Ahora el SDK mode debe activarse manualmente desde la TUI seleccionando el comando **CONNECT**.
2. **Selector de comandos SDK** — el panel de control muestra todos los comandos a la vez en dos bloques (base y movimiento), con resaltado fuerte del comando seleccionado para mejorar visibilidad.
3. **Navegación por bloques** — `←` y `→` mueven dentro del bloque actual; `↑` y `↓` saltan entre bloques para reducir pasos al navegar.
4. **Prompt de argumentos con validación** — para `up/down/left/right/forward/back` y `cw/ccw`, al pulsar `Enter` se solicita `x` por consola y se valida contra los rangos definidos por el SDK antes de enviar el comando.
5. **Detección NO SIGNAL** — el listener escribe un timestamp junto al último paquete de telemetría; si no se reciben datos en un intervalo configurable (por defecto 5 s), el panel muestra `NO SIGNAL`:
   - Indicador de conexión en el encabezado cambia a `● NO SIGNAL` en rojo.
   - La batería se muestra en rojo con la etiqueta `[NO SIGNAL]` y los campos de telemetría se muestran en rojo o en gris cuando no se tiene ningún paquete previo.
6. **Recuadro de respuesta** — las respuestas del dron se presentan en un bloque con borde (comando / resultado) y colores semánticos (`ok` verde, `error` rojo, `timeout` amarillo).

Detalles de la TUI y componentes internos:

- **Listener de estado** — escribe en `/tmp/tello_state_<PID>.txt` dos líneas: `timestamp` y `datos`; el `display()` compara `timestamp` con el tiempo actual para decidir si hay señal.
- **Keepalive** — envía `battery?` cada 10 s para evitar el aterrizaje por inactividad (límite SDK: 15 s).
- **Comandos con respuesta** — `execute_selected_command()` decide si el comando requiere argumentos; para comandos directos usa `send_command_response()` y para conexión usa `connect_drone()`. En ambos casos se abre puerto local 9000 y se guarda la respuesta en `/tmp/tello_resp_<PID>.txt` (timeout 5 s).
- **Limpieza** — al salir se restauran opciones del terminal y se eliminan los ficheros temporales.

## Estructura del proyecto

```text
03. Tello_Edu_Monitor/
└── tello_monitor.sh    # Script principal
```

## Notas

- El script permite ejecutar desde la TUI: `command`, `takeoff`, `land`, `streamon`, `streamoff`, `emergency`, `up x`, `down x`, `left x`, `right x`, `forward x`, `back x`, `cw x`, `ccw x`.
- El Tello transmite el estado a ~10-20 Hz de forma continua una vez que recibe el comando `command`; el script detecta además la falta de paquetes y muestra `NO SIGNAL` cuando corresponde.

## Referencia

- [Tello SDK 2.0 User Guide](https://dl-cdn.ryzerobotics.com/downloads/Tello/Tello%20SDK%202.0%20User%20Guide.pdf)
