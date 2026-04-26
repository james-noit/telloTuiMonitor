#!/usr/bin/env bash
# =============================================================================
# tello_monitor.sh — Monitor TUI + control de vuelo · Tello SDK 2.0
#   Comandos  : UDP 192.168.10.1:8889  (PC ↔ Tello)
#   Estado    : UDP 0.0.0.0:8890       (Tello → PC, ~10-20 Hz)
#   Navegación: ← → seleccionar  ·  Enter ejecutar  ·  q salir
#   Selector  : comandos de control SDK (con y sin argumentos)
# =============================================================================

# ─── Configuración ────────────────────────────────────────────────────────────
TELLO_IP="192.168.10.1"
TELLO_CMD_PORT=8889
TELLO_STATE_PORT=8890
TELLO_VIDEO_PORT=11111
STATE_FILE="/tmp/tello_state_$$.txt"
RESPONSE_FILE="/tmp/tello_resp_$$.txt"
VIDEO_VIEWER_LOG="/tmp/tello_video_viewer_$$.log"
VIDEO_STOP_FLAG_FILE="/tmp/tello_video_stop_$$.flag"
VIDEO_EVENT_FILE="/tmp/tello_video_event_$$.txt"
LOG_FILE="/tmp/tello_monitor_log_$$.txt"
INTERVAL=5          # segundos entre refresco automático del estado
VIDEO_PROBE_TIMEOUT=3
LOG_VISIBLE_LINES=6
MENU_ITEM_WIDTH=11

# ─── Colores ANSI ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
REV='\033[7m'       # vídeo inverso (resaltar botón seleccionado)
NC='\033[0m'

# ─── Estado TUI ───────────────────────────────────────────────────────────────
SELECTED=0          # índice del comando seleccionado en COMMAND_* arrays
LAST_CMD="—"
LAST_RESPONSE="—"
SIGNAL_TIMEOUT=5    # segundos sin datos → NO SIGNAL
_CLEANING=0
PROMPT_ARG_VALUE=""
VIDEO_VIEWER_PID=""
VIDEO_WATCHER_PID=""
VIDEO_LAST_STATUS="off"

# Comandos de control soportados (SDK 2.0, sección Control Commands)
COMMAND_LABELS=(
    "CONNECT"
    "TAKEOFF"
    "LAND"
    "STREAM ON"
    "STREAM OFF"
    "EMERGENCY"
    "UP x"
    "DOWN x"
    "LEFT x"
    "RIGHT x"
    "FWD x"
    "BACK x"
    "CW x"
    "CCW x"
)

COMMAND_BASES=(
    "command"
    "takeoff"
    "land"
    "streamon"
    "streamoff"
    "emergency"
    "up"
    "down"
    "left"
    "right"
    "forward"
    "back"
    "cw"
    "ccw"
)

COMMAND_COUNT=${#COMMAND_LABELS[@]}
COMMAND_ROW_SPLIT=6   # fila superior: base / fila inferior: movimiento

# ─── Guardar estado original del terminal ─────────────────────────────────────
ORIG_STTY=$(stty -g 2>/dev/null)

# ─── Limpieza al salir (Ctrl+C / kill / q) ────────────────────────────────────
cleanup() {
    (( _CLEANING )) && return
    _CLEANING=1
    log_info "Iniciando limpieza y salida del monitor"
    [[ -n "$ORIG_STTY" ]] && stty "$ORIG_STTY" 2>/dev/null
    tput cnorm 2>/dev/null
    if [[ -n "$VIDEO_VIEWER_PID" ]] && kill -0 "$VIDEO_VIEWER_PID" 2>/dev/null; then
        touch "$VIDEO_STOP_FLAG_FILE"
        send_command "streamoff"
        log_info "Se envio streamoff durante cleanup"
    fi
    echo -e "\n${YELLOW}Cerrando monitor Tello...${NC}"
    jobs -p | xargs -r kill 2>/dev/null
    rm -f "$STATE_FILE" "$RESPONSE_FILE" "$VIDEO_VIEWER_LOG" "$VIDEO_STOP_FLAG_FILE" "$VIDEO_EVENT_FILE" "$LOG_FILE"
    echo -e "${GREEN}Fin.${NC}"
    exit 0
}
trap cleanup INT TERM EXIT

# ─── Enviar comando UDP sin esperar respuesta (keepalive) ─────────────────────
send_command() {
    echo -n "$1" > /dev/udp/"$TELLO_IP"/"$TELLO_CMD_PORT" 2>/dev/null || true
}

# ─── Gestión de modo de entrada del terminal ──────────────────────────────────
enter_raw_mode() {
    stty -echo -icanon min 0 time 0 2>/dev/null
    tput civis 2>/dev/null
}

restore_input_mode() {
    [[ -n "$ORIG_STTY" ]] && stty "$ORIG_STTY" 2>/dev/null
    tput cnorm 2>/dev/null
}

# ─── Logging y trazabilidad ───────────────────────────────────────────────────
log_event() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts=$(date '+%H:%M:%S')
    printf '[%s] %-5s %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE"
}

log_info() { log_event "INFO" "$*"; }
log_warn() { log_event "WARN" "$*"; }
log_error() { log_event "ERROR" "$*"; }

consume_video_event() {
    if [[ -s "$VIDEO_EVENT_FILE" ]]; then
        local ev
        ev=$(tr -d '\r\n' < "$VIDEO_EVENT_FILE")
        rm -f "$VIDEO_EVENT_FILE"
        if [[ -n "$ev" ]]; then
            VIDEO_LAST_STATUS="$ev"
            case "$ev" in
                off)        log_info "Visor cerrado; stream de video desactivado" ;;
                viewer)     log_info "Visor de video activo" ;;
                bind_error) log_warn "Puerto de video ocupado" ;;
            esac
        fi
    fi
}

repeat_char() {
    local ch="$1"
    local count="$2"
    local out=""
    local i

    (( count <= 0 )) && return 0
    for ((i=0; i<count; i++)); do
        out+="$ch"
    done
    printf '%s' "$out"
}

fit_text() {
    local txt="$1"
    local max="$2"

    (( max <= 0 )) && { printf ''; return 0; }

    if (( ${#txt} <= max )); then
        printf '%s' "$txt"
    elif (( max <= 3 )); then
        printf '%.*s' "$max" "$txt"
    else
        printf '%.*s...' "$((max - 3))" "$txt"
    fi
}

# ─── Utilidades del flujo de video (UDP :11111) ─────────────────────────────
wait_command_response() {
    local timeout="${1:-6}"
    local elapsed=0

    while (( elapsed < timeout * 10 )); do
        if [[ -f "$RESPONSE_FILE" && -s "$RESPONSE_FILE" ]]; then
            LAST_RESPONSE=$(tr -d '\r\n' < "$RESPONSE_FILE")
            : > "$RESPONSE_FILE"
            return 0
        fi
        sleep 0.1
        ((elapsed++))
    done

    LAST_RESPONSE="sin respuesta (timeout)"
    log_warn "Timeout esperando respuesta del dron"
    return 1
}

prompt_yes_no() {
    local msg="$1"
    local ans

    restore_input_mode
    printf "\n  ${CYAN}%s [s/N]: ${NC}" "$msg"
    IFS= read -r ans
    enter_raw_mode

    if [[ "$ans" =~ ^([sS]|[sS][iI])$ ]]; then
        log_info "Prompt SI/NO confirmado: si"
        return 0
    fi

    log_info "Prompt SI/NO confirmado: no"
    return 1
}

probe_video_stream() {
    local timeout="${1:-3}"
    local out packets

    if ! command -v python3 &>/dev/null; then
        VIDEO_LAST_STATUS="no_rx"
        log_error "No se puede sondear video: python3 no disponible"
        return 1
    fi

    out=$(python3 - "$TELLO_VIDEO_PORT" "$timeout" <<'PYEOF'
import socket, sys, time
port = int(sys.argv[1])
timeout = float(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.settimeout(0.35)
packets = 0
total = 0
start = time.time()
try:
    sock.bind(('', port))
except Exception as e:
    print(f"bind_error:{str(e)[:80]}")
    sys.exit(2)
while time.time() - start < timeout:
    try:
        data, _ = sock.recvfrom(4096)
        if data:
            packets += 1
            total += len(data)
    except socket.timeout:
        continue
    except Exception:
        continue
sock.close()
elapsed = time.time() - start
if packets > 0:
    print(f"ok:{packets}:{total}:{elapsed:.1f}")
else:
    print(f"timeout:0:{total}:{elapsed:.1f}")
PYEOF
)

    if [[ "$out" == ok:* ]]; then
        packets=$(echo "$out" | awk -F: '{print $2}')
        VIDEO_LAST_STATUS="rx:${packets}"
        log_info "Flujo de video detectado en UDP:${TELLO_VIDEO_PORT} (paquetes=${packets})"
        return 0
    fi

    if [[ "$out" == bind_error:* ]]; then
        VIDEO_LAST_STATUS="bind_error"
        log_warn "No se pudo abrir UDP:${TELLO_VIDEO_PORT} (puerto ocupado)"
    else
        VIDEO_LAST_STATUS="no_rx"
        log_warn "No se detectaron paquetes de video en UDP:${TELLO_VIDEO_PORT}"
    fi
    return 1
}

is_video_viewer_running() {
    [[ -n "$VIDEO_VIEWER_PID" ]] && kill -0 "$VIDEO_VIEWER_PID" 2>/dev/null
}

start_video_exit_watcher() {
    local pid="$1"
    (
        while kill -0 "$pid" 2>/dev/null; do
            sleep 0.4
        done
        if [[ ! -f "$VIDEO_STOP_FLAG_FILE" ]]; then
            echo -n "streamoff" > /dev/udp/"$TELLO_IP"/"$TELLO_CMD_PORT" 2>/dev/null || true
            printf '%s\n' "auto streamoff: visor cerrado (q)" > "$RESPONSE_FILE"
            printf '%s\n' "off" > "$VIDEO_EVENT_FILE"
        fi
    ) &
    VIDEO_WATCHER_PID=$!
    log_info "Watcher de cierre de visor iniciado (pid=${VIDEO_WATCHER_PID})"
}

stop_video_viewer() {
    touch "$VIDEO_STOP_FLAG_FILE"

    if is_video_viewer_running; then
        kill "$VIDEO_VIEWER_PID" 2>/dev/null || true
    fi
    if [[ -n "$VIDEO_WATCHER_PID" ]] && kill -0 "$VIDEO_WATCHER_PID" 2>/dev/null; then
        kill "$VIDEO_WATCHER_PID" 2>/dev/null || true
    fi

    VIDEO_VIEWER_PID=""
    VIDEO_WATCHER_PID=""
    VIDEO_LAST_STATUS="off"
    log_info "Visor de video detenido"
}

launch_video_viewer() {
    if is_video_viewer_running; then
        LAST_RESPONSE="visor de video ya activo"
        log_info "Intento de abrir visor ignorado: ya estaba activo"
        return 0
    fi

    rm -f "$VIDEO_STOP_FLAG_FILE"

    if command -v ffplay &>/dev/null; then
        log_info "Abriendo visor con ffplay"
        ffplay -loglevel error -fflags nobuffer -flags low_delay -framedrop \
            "udp://0.0.0.0:${TELLO_VIDEO_PORT}?fifo_size=5000000&overrun_nonfatal=1" \
            >"$VIDEO_VIEWER_LOG" 2>&1 &
        VIDEO_VIEWER_PID=$!
    elif command -v mpv &>/dev/null; then
        log_info "Abriendo visor con mpv"
        mpv --no-terminal --profile=low-latency \
            "udp://0.0.0.0:${TELLO_VIDEO_PORT}" \
            >"$VIDEO_VIEWER_LOG" 2>&1 &
        VIDEO_VIEWER_PID=$!
    else
        LAST_RESPONSE="sin visor: instala ffplay o mpv"
        VIDEO_LAST_STATUS="rx_sin_visor"
        log_error "No se pudo abrir visor: no existe ffplay ni mpv"
        return 1
    fi

    sleep 0.2
    if ! kill -0 "$VIDEO_VIEWER_PID" 2>/dev/null; then
        LAST_RESPONSE="error al iniciar visor (revisa log)"
        VIDEO_LAST_STATUS="rx_sin_visor"
        log_error "El visor termino inmediatamente; revisar ${VIDEO_VIEWER_LOG}"
        return 1
    fi

    VIDEO_LAST_STATUS="viewer"
    printf '%s\n' "viewer" > "$VIDEO_EVENT_FILE"
    start_video_exit_watcher "$VIDEO_VIEWER_PID"
    LAST_RESPONSE="visor abierto (q en ventana = streamoff)"
    log_info "Visor abierto (pid=${VIDEO_VIEWER_PID})"
    return 0
}

handle_streamon() {
    log_info "Ejecutando comando streamon"
    send_command_response "streamon"
    wait_command_response 6 || return 1

    if [[ "$LAST_RESPONSE" != "ok" ]]; then
        log_warn "streamon respondio: ${LAST_RESPONSE}"
        return 1
    fi

    if is_video_viewer_running; then
        VIDEO_LAST_STATUS="viewer"
        LAST_RESPONSE="ok + visor de video ya activo"
        log_info "streamon OK con visor ya activo"
        return 0
    fi

    if probe_video_stream "$VIDEO_PROBE_TIMEOUT"; then
        LAST_RESPONSE="ok + video UDP:${TELLO_VIDEO_PORT}"
        if prompt_yes_no "Flujo detectado. Quieres abrir visor de video?"; then
            launch_video_viewer || true
        fi
    else
        LAST_RESPONSE="ok, pero sin paquetes en UDP:${TELLO_VIDEO_PORT}"
        if prompt_yes_no "No se detecto flujo. Abrir visor igualmente?"; then
            launch_video_viewer || true
        fi
    fi
}

handle_streamoff() {
    log_info "Ejecutando comando streamoff"
    stop_video_viewer
    send_command_response "streamoff"
}

# ─── Metadatos de parámetros por comando ──────────────────────────────────────
command_arg_hint() {
    case "$1" in
        up|down|left|right|forward|back) echo "x: 20-500 cm" ;;
        cw|ccw)                          echo "x: 1-360 grados" ;;
        *)                               echo "sin argumentos" ;;
    esac
}

prompt_command_arg() {
    local base="$1"
    local min max unit val

    case "$base" in
        up|down|left|right|forward|back)
            min=20
            max=500
            unit="cm"
            ;;
        cw|ccw)
            min=1
            max=360
            unit="grados"
            ;;
        *)
            return 1
            ;;
    esac

    while true; do
        restore_input_mode
        printf "\n"
        printf "  ${CYAN}${BOLD}Comando: %s${NC}\n" "$base"
        printf "  ${DIM}Introduce x entre %d y %d (%s). Pulsa 'c' para cancelar.${NC}\n" "$min" "$max" "$unit"
        printf "  x = "
        IFS= read -r val

        if [[ "$val" == "c" || "$val" == "C" ]]; then
            LAST_CMD="${base} x"
            LAST_RESPONSE="cancelado por usuario"
            log_info "Entrada de argumento cancelada para comando ${base}"
            enter_raw_mode
            return 1
        fi

        if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max )); then
            PROMPT_ARG_VALUE="$val"
            log_info "Argumento valido para ${base}: ${val}"
            enter_raw_mode
            return 0
        fi

        printf "  ${RED}Valor invalido: debe estar entre %d y %d.${NC}\n" "$min" "$max"
        log_warn "Argumento invalido para ${base}: ${val}"
    done
}

execute_selected_command() {
    local base="${COMMAND_BASES[$SELECTED]}"
    local cmd="$base"

    case "$base" in
        command)
            connect_drone
            return 0
            ;;
        streamon)
            handle_streamon
            return 0
            ;;
        streamoff)
            handle_streamoff
            return 0
            ;;
        up|down|left|right|forward|back|cw|ccw)
            if ! prompt_command_arg "$base"; then
                return 1
            fi
            cmd="${base} ${PROMPT_ARG_VALUE}"
            ;;
    esac

    send_command_response "$cmd"
}

menu_item() {
    local idx="$1"
    local label="${COMMAND_LABELS[$idx]}"
    local width="${MENU_ITEM_WIDTH:-11}"

    if (( idx == SELECTED )); then
        printf "${REV}${BOLD} %-*.*s ${NC} " "$width" "$width" "$label"
    else
        printf "${DIM} %-*.*s ${NC} " "$width" "$width" "$label"
    fi
}

# ─── Enviar comando y capturar respuesta vía python3 (async) ──────────────────
# Usa puerto local 9000 (igual que Tello3.py oficial) para que el Tello
# sepa a qué puerto responder.
send_command_response() {
    local cmd="$1"
    if ! command -v python3 &>/dev/null; then
        LAST_CMD="$cmd"
        LAST_RESPONSE="error: python3 no disponible"
        printf '%s\n' "$LAST_RESPONSE" > "$RESPONSE_FILE"
        log_error "No se puede enviar comando '${cmd}': python3 no disponible"
        return 1
    fi

    LAST_CMD="$cmd"
    LAST_RESPONSE="enviando..."
    log_info "Enviando comando: ${cmd}"
    rm -f "$RESPONSE_FILE"
    python3 - "$cmd" "$RESPONSE_FILE" "$TELLO_IP" "$TELLO_CMD_PORT" <<'PYEOF' &
import socket, sys
cmd  = sys.argv[1].encode()
rf   = sys.argv[2]
ip   = sys.argv[3]
port = int(sys.argv[4])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.settimeout(5)
resp = 'sin respuesta (timeout)'
try:
    sock.bind(('', 9000))
    sock.sendto(cmd, (ip, port))
    data, _ = sock.recvfrom(1024)
    resp = data.decode('utf-8', errors='ignore').strip()
except Exception as e:
    resp = str(e)[:50]
finally:
    try: sock.close()
    except: pass
with open(rf, 'w') as f:
    f.write(resp + '\n')
PYEOF
}

# ─── Inicializar SDK mode (python3, bloqueante) ───────────────────────────────
init_sdk() {
    python3 - "$TELLO_IP" "$TELLO_CMD_PORT" 2>&1 <<'PYEOF'
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.settimeout(5)
try:
    sock.bind(('', 9000))
    sock.sendto(b'command', (sys.argv[1], int(sys.argv[2])))
    data, _ = sock.recvfrom(1024)
    print("  \u2713 SDK mode:", data.decode('utf-8', errors='ignore').strip())
except socket.timeout:
    print("  \u2717 Tello no respondio (timeout)")
except Exception as e:
    print("  \u2717 Error:", e)
finally:
    try: sock.close()
    except: pass
PYEOF
}

# ─── Conectar al dron desde TUI (envía "command", async) ─────────────────────
connect_drone() {
    if ! command -v python3 &>/dev/null; then
        LAST_CMD="command"
        LAST_RESPONSE="error: python3 no disponible"
        printf '%s\n' "$LAST_RESPONSE" > "$RESPONSE_FILE"
        log_error "No se puede ejecutar CONNECT: python3 no disponible"
        return 1
    fi

    LAST_CMD="command"
    LAST_RESPONSE="enviando..."
    log_info "Enviando CONNECT (command)"
    rm -f "$RESPONSE_FILE"
    python3 - "command" "$RESPONSE_FILE" "$TELLO_IP" "$TELLO_CMD_PORT" <<'PYEOF' &
import socket, sys
cmd  = sys.argv[1].encode()
rf   = sys.argv[2]
ip   = sys.argv[3]
port = int(sys.argv[4])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.settimeout(5)
resp = 'sin respuesta (timeout)'
try:
    sock.bind(('', 9000))
    sock.sendto(cmd, (ip, port))
    data, _ = sock.recvfrom(1024)
    resp = data.decode('utf-8', errors='ignore').strip()
except Exception as e:
    resp = str(e)[:50]
finally:
    try: sock.close()
    except: pass
with open(rf, 'w') as f:
    f.write(resp + '\n')
PYEOF
}

# ─── Listener UDP de estado en puerto 8890 ────────────────────────────────────
# El listener escribe también un timestamp (epoch) en STATE_FILE para detectar
# pérdida de señal: línea 1 = timestamp, línea 2 = datos de estado.
start_state_listener() {
    local listener_pid=""

    if command -v python3 &>/dev/null; then
        log_info "Iniciando listener de estado con python3 en UDP:${TELLO_STATE_PORT}"
        python3 - "$STATE_FILE" "$TELLO_STATE_PORT" <<'PYEOF' &
import socket, sys, time
sf   = sys.argv[1]
port = int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    sock.bind(('', port))
except Exception:
    with open(sf, 'w') as f:
        f.write('0\n')
        f.write('listener_error: bind failed\n')
    raise
while True:
    try:
        data, _ = sock.recvfrom(1024)
        line = data.decode('utf-8', errors='ignore').strip()
        if line:
            with open(sf, 'w') as f:
                f.write(str(int(time.time())) + '\n')
                f.write(line + '\n')
    except Exception:
        time.sleep(0.1)
PYEOF
        listener_pid=$!
    elif command -v socat &>/dev/null; then
        log_info "Iniciando listener de estado con socat en UDP:${TELLO_STATE_PORT}"
        (socat -u "UDP-RECVFROM:${TELLO_STATE_PORT},reuseaddr,fork" STDOUT 2>/dev/null \
            | while IFS= read -r line; do
                [[ -n "$line" ]] && printf '%s\n%s\n' "$(date +%s)" "$line" > "$STATE_FILE"
              done) &
        listener_pid=$!
    elif command -v nc &>/dev/null; then
        log_info "Iniciando listener de estado con nc en UDP:${TELLO_STATE_PORT}"
        local nc_opts="-u -l"
        nc --help 2>&1 | grep -q -- '-p' && nc_opts="-u -l -p"
        (while true; do
            # shellcheck disable=SC2086
            nc $nc_opts "$TELLO_STATE_PORT" 2>/dev/null \
                | while IFS= read -r line; do
                    [[ -n "$line" ]] && printf '%s\n%s\n' "$(date +%s)" "$line" > "$STATE_FILE"
                  done
        done) &
        listener_pid=$!
    else
        echo -e "${RED}Error: se requiere 'socat', 'python3' o 'nc'.${NC}"
        log_error "No hay herramienta disponible para listener de estado"
        exit 1
    fi

    sleep 0.2
    if [[ -z "$listener_pid" ]] || ! kill -0 "$listener_pid" 2>/dev/null; then
        log_error "El listener de estado no quedo activo (UDP:${TELLO_STATE_PORT})"
    else
        log_info "Listener de estado activo (pid=${listener_pid})"
    fi
}

# ─── Keepalive: evita aterrizaje automático (límite SDK: 15 s sin comandos) ───
start_keepalive() {
    log_info "Keepalive iniciado (battery? cada 10s)"
    (while true; do
        sleep 10
        send_command "battery?" 2>/dev/null
    done) &
}

# ─── Verificar conectividad ───────────────────────────────────────────────────
check_connectivity() {
    printf "  ${YELLOW}Comprobando conectividad con %s...${NC}\n" "$TELLO_IP"
    if ! ping -c1 -W2 "$TELLO_IP" &>/dev/null; then
        printf "  ${RED}No se puede alcanzar %s.${NC}\n" "$TELLO_IP"
        printf "  ${DIM}Conectate a la red WiFi del Tello (TELLO-XXXXXX) e intenta de nuevo.${NC}\n"
        exit 1
    fi
    printf "  ${GREEN}Tello localizado en %s${NC}\n" "$TELLO_IP"
}

# ─── Parsear campo del string de estado ───────────────────────────────────────
get_field() {
    echo "$1" | tr ';' '\n' | awk -F':' -v f="$2" '$1==f{print $2; exit}'
}

# ─── Barra visual de batería ──────────────────────────────────────────────────
bat_bar() {
    local val="${1:-0}"
    [[ "$val" =~ ^[0-9]+$ ]] || val=0
    local filled=$(( val / 10 )) bar=""
    for ((i=0; i<filled; i++));  do bar+="█"; done
    for ((i=filled; i<10; i++)); do bar+="░"; done
    echo "$bar"
}

# ─── Dibujar TUI completa ─────────────────────────────────────────────────────
display() {
    local ts state
    local bat="" h="" pitch="" roll="" yaw="" templ="" temph=""
    local tof="" vgx="" vgy="" vgz="" baro="" tiempo=""
    local state_ts=0 no_signal=0
    local video_line
    local cols lines panel_width rule_line
    local box_inner_w log_visible_lines compact_controls=0

    ts=$(date '+%H:%M:%S')
    consume_video_event

    cols=$(tput cols 2>/dev/null)
    lines=$(tput lines 2>/dev/null)
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=100
    [[ "$lines" =~ ^[0-9]+$ ]] || lines=36
    (( cols < 64 )) && cols=64

    panel_width=$(( cols - 4 ))
    box_inner_w=$(( panel_width - 2 ))
    rule_line=$(repeat_char "━" "$panel_width")

    # Altura de LOG adaptativa para evitar recortes verticales.
    log_visible_lines="$LOG_VISIBLE_LINES"
    if (( lines <= 28 )); then
        log_visible_lines=3
    elif (( lines <= 34 )); then
        log_visible_lines=4
    elif (( lines <= 42 )); then
        log_visible_lines=5
    elif (( lines <= 50 )); then
        log_visible_lines=6
    else
        log_visible_lines=8
    fi

    # Presentación compacta en terminales estrechos.
    (( panel_width < 96 )) && compact_controls=1

    # Ajustar ancho de botón según tamaño de terminal.
    if (( compact_controls )); then
        MENU_ITEM_WIDTH=10
    else
        MENU_ITEM_WIDTH=11
    fi

    # Leer respuesta pendiente del último comando
    if [[ -f "$RESPONSE_FILE" && -s "$RESPONSE_FILE" ]]; then
        LAST_RESPONSE=$(tr -d '\r\n' < "$RESPONSE_FILE")
        log_info "Respuesta recibida para '${LAST_CMD}': ${LAST_RESPONSE}"
        : > "$RESPONSE_FILE"
    fi

    # Leer último estado del dron (línea 1 = timestamp, línea 2 = datos)
    if [[ -s "$STATE_FILE" ]]; then
        state_ts=$(head -1 "$STATE_FILE" | tr -d '\r\n')
        state=$(tail -1 "$STATE_FILE" | tr -d '\r\n')
        # Validar que state_ts es numérico
        [[ "$state_ts" =~ ^[0-9]+$ ]] || state_ts=0
        local now_ts; now_ts=$(date +%s)
        (( now_ts - state_ts > SIGNAL_TIMEOUT )) && no_signal=1
        bat=$(get_field   "$state" "bat");   h=$(get_field     "$state" "h")
        pitch=$(get_field "$state" "pitch"); roll=$(get_field  "$state" "roll")
        yaw=$(get_field   "$state" "yaw");   templ=$(get_field "$state" "templ")
        temph=$(get_field "$state" "temph"); tof=$(get_field   "$state" "tof")
        vgx=$(get_field   "$state" "vgx");   vgy=$(get_field   "$state" "vgy")
        vgz=$(get_field   "$state" "vgz");   baro=$(get_field  "$state" "baro")
        tiempo=$(get_field "$state" "time")
    fi

    # ── Indicador de conexión ──────────────────────────────────────────────────
    local conn_indicator conn_label
    if [[ -z "${state:-}" || "$no_signal" -eq 1 ]]; then
        conn_indicator="${RED}${BOLD}● NO SIGNAL${NC}"
        conn_label="${RED}"
    else
        conn_indicator="${GREEN}${BOLD}● ONLINE${NC}"
        conn_label="${NC}"
    fi

    # Color de batería (NO SIGNAL → siempre rojo)
    local bat_color="$GREEN" bat_num="${bat:-0}"
    [[ "$bat_num" =~ ^[0-9]+$ ]] || bat_num=0
    if [[ -z "${state:-}" || "$no_signal" -eq 1 ]]; then
        bat_color="$RED"
    else
        (( bat_num < 20 )) && bat_color="$RED"
        (( bat_num >= 20 && bat_num < 50 )) && bat_color="$YELLOW"
    fi
    local bar; bar=$(bat_bar "$bat_num")

    # Color de la respuesta
    local rc="$NC"
    [[ "$LAST_RESPONSE" == "ok" ]]         && rc="${GREEN}${BOLD}"
    [[ "$LAST_RESPONSE" == "error" ]]      && rc="${RED}${BOLD}"
    [[ "$LAST_RESPONSE" == *"timeout"* ]]  && rc="${YELLOW}${BOLD}"
    [[ "$LAST_RESPONSE" == "enviando"* ]]  && rc="${YELLOW}"

    # Selector de comandos en rejilla + hint de argumentos
    local curr_label="${COMMAND_LABELS[$SELECTED]}"
    local curr_base="${COMMAND_BASES[$SELECTED]}"
    local i
    local arg_hint; arg_hint=$(command_arg_hint "$curr_base")
    local cmd_preview="$curr_base"
    case "$curr_base" in
        up|down|left|right|forward|back|cw|ccw)
            cmd_preview="${curr_base} <x>"
            ;;
    esac

    # Estado resumido del stream de video
    if is_video_viewer_running; then
        video_line="${GREEN}${BOLD}visor activo (UDP:${TELLO_VIDEO_PORT})${NC}"
    else
        case "$VIDEO_LAST_STATUS" in
            rx:*)       video_line="${YELLOW}flujo detectado (sin visor)${NC}" ;;
            no_rx)      video_line="${RED}sin flujo en UDP:${TELLO_VIDEO_PORT}${NC}" ;;
            bind_error) video_line="${RED}puerto ${TELLO_VIDEO_PORT} ocupado${NC}" ;;
            rx_sin_visor) video_line="${YELLOW}flujo detectado, falta visor (ffplay/mpv)${NC}" ;;
            *)          video_line="${DIM}off${NC}" ;;
        esac
    fi

    # ── Dibujar ───────────────────────────────────────────────────────────────
    clear
    printf "\n"
    printf "  ${CYAN}${BOLD}%s${NC}\n" "$rule_line"
    printf "  ${CYAN}${BOLD}   TELLO MONITOR  ·  SDK 2.0  ·  %s${NC}   %b\n" "$ts" "$conn_indicator"
    printf "  ${CYAN}${BOLD}%s${NC}\n" "$rule_line"
    printf "\n"

    # ── Estado del dron ───────────────────────────────────────────────────────
    if [[ -z "${state:-}" ]]; then
        printf "  ${YELLOW}Esperando datos del Tello...${NC}\n"
        printf "  ${DIM}Conectado a la red WiFi TELLO-XXXXXX?${NC}\n"
        printf "  ${RED}${BOLD}Bateria   :  --- [NO SIGNAL] ░░░░░░░░░░${NC}\n"
        printf "  ${DIM}Altura    :  --- cm${NC}\n"
        printf "  ${DIM}Dist. ToF :  --- cm${NC}\n"
        printf "  ${DIM}Barometro :  --- cm${NC}\n"
        printf "\n"
        printf "  ${DIM}${BLUE}Actitud  ${NC}${DIM}  Pitch:    ?  Roll:    ?  Yaw:    ?${NC}\n"
        printf "  ${DIM}${BLUE}Velocidad${NC}${DIM}  Vx:    ?  Vy:    ?  Vz:    ? cm/s${NC}\n"
        printf "  ${DIM}Temp      :  ? C - ? C   Motor: ? s${NC}\n"
    elif (( no_signal )); then
        printf "  ${RED}${BOLD}Bateria   :  %3s%% [NO SIGNAL] %s${NC}\n" \
               "${bat:-?}" "$bar"
        printf "  ${conn_label}Altura    :${NC}  %s cm\n"  "${h:-?}"
        printf "  ${conn_label}Dist. ToF :${NC}  %s cm\n"  "${tof:-?}"
        printf "  ${conn_label}Barometro :${NC}  %s cm\n"  "${baro:-?}"
        printf "\n"
        printf "  ${RED}${BLUE}Actitud  ${NC}${RED}  Pitch: %4s  Roll: %4s  Yaw: %4s${NC}\n" \
               "${pitch:-?}" "${roll:-?}" "${yaw:-?}"
        printf "  ${RED}${BLUE}Velocidad${NC}${RED}  Vx: %4s  Vy: %4s  Vz: %4s cm/s${NC}\n" \
               "${vgx:-?}" "${vgy:-?}" "${vgz:-?}"
        printf "  ${RED}Temp      :${NC}${RED}  %s C - %s C   Motor: %s s${NC}\n" \
               "${templ:-?}" "${temph:-?}" "${tiempo:-?}"
    else
        printf "  ${BOLD}Bateria   :${NC}  ${bat_color}${BOLD}%3s%%${NC}  ${bat_color}%s${NC}\n" \
               "${bat:-?}" "$bar"
        printf "  ${BOLD}Altura    :${NC}  %s cm\n"         "${h:-?}"
        printf "  ${BOLD}Dist. ToF :${NC}  %s cm\n"         "${tof:-?}"
        printf "  ${BOLD}Barometro :${NC}  %s cm\n"         "${baro:-?}"
        printf "\n"
        printf "  ${BOLD}${BLUE}Actitud  ${NC}  Pitch: ${BOLD}%4s${NC}  Roll: ${BOLD}%4s${NC}  Yaw: ${BOLD}%4s${NC}\n" \
               "${pitch:-?}" "${roll:-?}" "${yaw:-?}"
        printf "  ${BOLD}${BLUE}Velocidad${NC}  Vx: ${BOLD}%4s${NC}  Vy: ${BOLD}%4s${NC}  Vz: ${BOLD}%4s${NC} cm/s\n" \
               "${vgx:-?}" "${vgy:-?}" "${vgz:-?}"
        printf "  ${BOLD}Temp      :${NC}  %s C - %s C   Motor: %s s\n" \
               "${templ:-?}" "${temph:-?}" "${tiempo:-?}"
    fi

    printf "\n"

    # ── Panel de control ──────────────────────────────────────────────────────
    printf "  ${CYAN}${BOLD}%s${NC}\n" "$rule_line"
    printf "  ${BOLD}  CONTROL${NC}  ${DIM}← → mover  ·  ↑ ↓ cambiar bloque  ·  Enter ejecutar  ·  q salir${NC}\n"
    printf "\n"
    printf "  ${DIM}  Comandos base${NC}\n"
    if (( compact_controls )); then
        printf "    "
        for ((i=0; i<3; i++)); do
            menu_item "$i"
        done
        printf "\n"
        printf "    "
        for ((i=3; i<COMMAND_ROW_SPLIT; i++)); do
            menu_item "$i"
        done
        printf "\n\n"
    else
        printf "    "
        for ((i=0; i<COMMAND_ROW_SPLIT; i++)); do
            menu_item "$i"
        done
        printf "\n\n"
    fi

    printf "  ${DIM}  Movimiento y rotacion${NC}\n"
    if (( compact_controls )); then
        printf "    "
        for ((i=COMMAND_ROW_SPLIT; i<COMMAND_ROW_SPLIT+4; i++)); do
            menu_item "$i"
        done
        printf "\n"
        printf "    "
        for ((i=COMMAND_ROW_SPLIT+4; i<COMMAND_COUNT; i++)); do
            menu_item "$i"
        done
        printf "\n\n"
    else
        printf "    "
        for ((i=COMMAND_ROW_SPLIT; i<COMMAND_COUNT; i++)); do
            menu_item "$i"
        done
        printf "\n\n"
    fi

    printf "    ${BOLD}Seleccion:${NC} [%d/%d] %s\n" "$((SELECTED + 1))" "$COMMAND_COUNT" "$curr_label"
    printf "\n"
    printf "    ${BOLD}Comando:${NC} %s\n" "$cmd_preview"
    printf "    ${BOLD}Parametro:${NC} %s\n" "$arg_hint"
    printf "\n"

    # ── Recuadro de respuesta ─────────────────────────────────────────────────
    local resp_title=" Respuesta del dron "
    local resp_title_fit resp_title_fill
    local cmd_prefix=" Comando  : "
    local res_prefix=" Resultado: "
    local cmd_room res_room cmd_txt res_txt cmd_pad res_pad

    resp_title_fit=$(fit_text "$resp_title" "$box_inner_w")
    resp_title_fill=$(( box_inner_w - ${#resp_title_fit} ))
    printf "  ${CYAN}${BOLD}┌%s%s┐${NC}\n" "$resp_title_fit" "$(repeat_char "─" "$resp_title_fill")"

    cmd_room=$(( box_inner_w - ${#cmd_prefix} ))
    (( cmd_room < 1 )) && cmd_room=1
    cmd_txt=$(fit_text "$LAST_CMD" "$cmd_room")
    cmd_pad=$(( cmd_room - ${#cmd_txt} ))
    printf "  ${CYAN}${BOLD}│${NC}%s%s%*s${CYAN}${BOLD}│${NC}\n" "$cmd_prefix" "$cmd_txt" "$cmd_pad" ""

    res_room=$(( box_inner_w - ${#res_prefix} ))
    (( res_room < 1 )) && res_room=1
    res_txt=$(fit_text "$LAST_RESPONSE" "$res_room")
    res_pad=$(( res_room - ${#res_txt} ))
    printf "  ${CYAN}${BOLD}│${NC}%s${rc}%s${NC}%*s${CYAN}${BOLD}│${NC}\n" "$res_prefix" "$res_txt" "$res_pad" ""
    printf "  ${CYAN}${BOLD}└%s┘${NC}\n" "$(repeat_char "─" "$box_inner_w")"
    printf "\n"
    printf "  ${CYAN}${BOLD}%s${NC}\n" "$rule_line"
    printf "  ${DIM}Estado: actualizacion automatica cada %ds${NC}\n" "$INTERVAL"
    printf "  ${DIM}Video:${NC} %b\n" "$video_line"

    # ── Ventana de trazabilidad ──────────────────────────────────────────────
    local log_lines line
    local log_title=" LOG (eventos recientes) "
    local log_title_fit log_title_fill
    local log_content_w
    printf "\n"
    log_title_fit=$(fit_text "$log_title" "$box_inner_w")
    log_title_fill=$(( box_inner_w - ${#log_title_fit} ))
    log_content_w=$(( box_inner_w - 1 ))
    (( log_content_w < 8 )) && log_content_w=8

    printf "  ${CYAN}${BOLD}┌%s%s┐${NC}\n" "$log_title_fit" "$(repeat_char "─" "$log_title_fill")"
    if [[ -s "$LOG_FILE" ]]; then
        mapfile -t log_lines < <(tail -n 120 "$LOG_FILE" | fold -s -w "$log_content_w" | tail -n "$log_visible_lines")
        for line in "${log_lines[@]}"; do
            printf "  ${CYAN}${BOLD}│${NC} %-*.*s${CYAN}${BOLD}│${NC}\n" "$log_content_w" "$log_content_w" "$line"
        done
        local remain=$(( log_visible_lines - ${#log_lines[@]} ))
        while (( remain > 0 )); do
            printf "  ${CYAN}${BOLD}│${NC} %-*s${CYAN}${BOLD}│${NC}\n" "$log_content_w" ""
            ((remain--))
        done
    else
        printf "  ${CYAN}${BOLD}│${NC} %-*.*s${CYAN}${BOLD}│${NC}\n" "$log_content_w" "$log_content_w" "Sin eventos aun"
        local idx
        for ((idx=1; idx<log_visible_lines; idx++)); do
            printf "  ${CYAN}${BOLD}│${NC} %-*s${CYAN}${BOLD}│${NC}\n" "$log_content_w" ""
        done
    fi
    printf "  ${CYAN}${BOLD}└%s┘${NC}\n" "$(repeat_char "─" "$box_inner_w")"
}

# ─── Leer tecla con soporte de secuencias de escape (flechas) ─────────────────
read_key() {
    local k1="" k2="" k3="" status=1

    # En modo raw + read -n, Enter puede llegar como lectura vacía con status 0.
    IFS= read -r -s -t 0.15 -n 1 k1 2>/dev/null
    status=$?
    (( status != 0 )) && return 1

    if [[ -z "$k1" ]]; then
        printf '__ENTER__'
        return 0
    fi

    if [[ "$k1" == $'\e' ]]; then
        IFS= read -r -s -t 0.05 -n 1 k2 2>/dev/null || true
        IFS= read -r -s -t 0.05 -n 1 k3 2>/dev/null || true
    fi
    printf '%s' "${k1}${k2}${k3}"
}

# ─── MAIN ─────────────────────────────────────────────────────────────────────
clear
rm -f "$LOG_FILE" "$VIDEO_EVENT_FILE"
log_info "Inicio del monitor"
START_COLS=$(tput cols 2>/dev/null)
[[ "$START_COLS" =~ ^[0-9]+$ ]] || START_COLS=100
(( START_COLS < 64 )) && START_COLS=64
START_RULE=$(repeat_char "━" "$((START_COLS - 4))")
printf "\n"
printf "  ${CYAN}${BOLD}%s${NC}\n" "$START_RULE"
printf "  ${CYAN}${BOLD}     TELLO MONITOR  ·  SDK 2.0${NC}\n"
printf "  ${CYAN}${BOLD}%s${NC}\n" "$START_RULE"
printf "\n"

printf "  ${YELLOW}[1/2]${NC} Iniciando listener de estado (UDP :%d)...\n" "$TELLO_STATE_PORT"
start_state_listener
sleep 0.3

printf "  ${YELLOW}[2/2]${NC} Iniciando keepalive (cada 10 s)...\n"
start_keepalive
sleep 0.5

printf "  ${DIM}Selecciona el comando CONNECT para iniciar el SDK mode.${NC}\n"
sleep 1

# Activar modo raw del terminal (sin eco, sin buffer de línea)
enter_raw_mode

display      # Primer dibujo

# ─── Bucle principal ──────────────────────────────────────────────────────────
NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))

while true; do
    key=$(read_key)

    case "$key" in
        $'\e[D')                    # ← flecha izquierda
            SELECTED=$(( (SELECTED - 1 + COMMAND_COUNT) % COMMAND_COUNT ))
            display
            NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))
            ;;
        $'\e[C')                    # → flecha derecha
            SELECTED=$(( (SELECTED + 1) % COMMAND_COUNT ))
            display
            NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))
            ;;
        $'\e[A')                    # ↑ flecha arriba: saltar a bloque superior
            if (( SELECTED >= COMMAND_ROW_SPLIT )); then
                target=$(( SELECTED - COMMAND_ROW_SPLIT ))
                (( target >= COMMAND_ROW_SPLIT )) && target=$(( COMMAND_ROW_SPLIT - 1 ))
                SELECTED=$target
                display
                NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))
            fi
            ;;
        $'\e[B')                    # ↓ flecha abajo: saltar a bloque inferior
            if (( SELECTED < COMMAND_ROW_SPLIT )); then
                target=$(( SELECTED + COMMAND_ROW_SPLIT ))
                (( target >= COMMAND_COUNT )) && target=$(( COMMAND_COUNT - 1 ))
                SELECTED=$target
                display
                NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))
            fi
            ;;
        '__ENTER__'|$'\n'|$'\r')     # Enter: ejecutar opción seleccionada
            execute_selected_command
            display
            NEXT_REFRESH=$(( $(date +%s) + INTERVAL ))
            ;;
        'q'|'Q')                    # q: salir
            cleanup
            ;;
    esac

    # Redibujar si llegó una respuesta nueva o si expiró el intervalo
    NOW=$(date +%s)
    if [[ -f "$RESPONSE_FILE" && -s "$RESPONSE_FILE" ]] || (( NOW >= NEXT_REFRESH )); then
        display
        NEXT_REFRESH=$(( NOW + INTERVAL ))
    fi
done
