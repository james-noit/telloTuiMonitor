# Tello Edu Monitor

Idioma: [Español](README.es.md) | [English](README.md)

Controla y monitoriza tu DJI Tello o Tello EDU desde una interfaz de terminal.

![Main Panel](Resources/img/mainPanel+VideoStream.png)

## Inicio rápido

1. Conecta tu ordenador a la red Wi-Fi del dron: TELLO-XXXXXX.
2. Instala herramientas necesarias:
   - Bash 4+
   - Python 3
   - Una herramienta de escucha UDP: socat (recomendado), o nc
3. Opcional para ventana de vídeo:
   - ffplay (recomendado) o mpv
4. Ejecuta:

```bash
chmod +x tello_monitor.sh
./tello_monitor.sh
```

1. En la TUI:
   - Selecciona primero CONNECT.
   - Luego usa TAKEOFF, LAND, comandos de movimiento y STREAM ON/OFF.

## Qué ofrece

- Panel de telemetría en vivo (batería, altura, actitud, velocidad, temperatura y tiempo de motor).
- Selector por teclado para comandos de vuelo y movimiento.
- Verificación de stream en UDP 11111 tras STREAM ON.
- Pregunta opcional para abrir visor de vídeo.
- Apagado automático de stream al cerrar la ventana de vídeo con q.
- Panel de LOG de eventos al final de la TUI.
- Presentación adaptable al tamaño de terminal.

## Requisitos

- Linux o macOS
- Bash 4+
- Python 3
- Conexión Wi-Fi a TELLO-XXXXXX

Opcional pero recomendado:

- socat para fallback de escucha UDP
- ffplay (de ffmpeg) o mpv para vista de vídeo

Ejemplos de instalación:

```bash
# Debian / Ubuntu
sudo apt install socat ffmpeg

# Arch Linux
sudo pacman -S socat ffmpeg

# macOS
brew install socat ffmpeg
```

## Controles de teclado

- Izquierda/Derecha: mover selección dentro del bloque actual
- Arriba/Abajo: cambiar entre bloque base y bloque de movimiento
- Enter: ejecutar comando seleccionado
- c: cancelar prompt de valor numérico para movimiento
- q: salir del monitor
- Ctrl+C: salir del monitor

## Comandos

| Comando | Argumento | Rango válido |
| --- | --- | --- |
| command | No | - |
| takeoff | No | - |
| land | No | - |
| streamon | No | - |
| streamoff | No | - |
| emergency | No | - |
| up x | Sí | 20-500 cm |
| down x | Sí | 20-500 cm |
| left x | Sí | 20-500 cm |
| right x | Sí | 20-500 cm |
| forward x | Sí | 20-500 cm |
| back x | Sí | 20-500 cm |
| cw x | Sí | 1-360 grados |
| ccw x | Sí | 1-360 grados |

## Streaming de vídeo

Al ejecutar STREAM ON:

1. El monitor envía streamon.
2. Comprueba si llegan paquetes UDP al puerto 11111.
3. Pregunta si quieres abrir una ventana de vídeo.
4. Si confirmas, inicia ffplay o mpv.
5. Si pulsas q en la ventana de vídeo, envía streamoff automáticamente.

## Puertos de red

| Flujo | Protocolo | Dirección | Puerto |
| --- | --- | --- | --- |
| PC -> Tello comandos | UDP | 192.168.10.1 | 8889 |
| Tello -> PC respuesta comandos | UDP | 0.0.0.0 bind | 9000 |
| Tello -> PC estado | UDP | 0.0.0.0 bind | 8890 |
| Tello -> PC vídeo | UDP | 0.0.0.0 bind | 11111 |

## Solución de problemas

- Sin telemetría:
  - Verifica que estás en la red TELLO-XXXXXX.
  - Envía CONNECT primero.
- STREAM ON responde ok pero no hay vídeo:
  - Revisa estabilidad de red.
  - Comprueba si el puerto 11111 está ocupado.
  - Prueba abrir visor igualmente desde el prompt.
- No se abre ventana de vídeo:
  - Instala ffplay (ffmpeg) o mpv.
- Timeouts en comandos:
  - Acércate al dron.
  - Revisa batería.

## Seguridad

- Vuela siempre en un área abierta y segura.
- Prueba primero despegue y aterrizaje.
- Ten el comando emergency preparado.
- El script envía keepalive periódico para reducir auto-aterrizaje por inactividad.

## Estructura del proyecto

```text
03. Tello_Edu_Monitor/
├── tello_monitor.sh
├── README.md
└── README.es.md
```

## Referencia

- [Tello SDK 2.0 User Guide](https://dl-cdn.ryzerobotics.com/downloads/Tello/Tello%20SDK%202.0%20User%20Guide.pdf)
