#!/bin/bash

# --- CONFIGURACIÓN FIJA ---
WIFI_PASS="SN2008@+"
WIFI_IFACE="wlan0"
LAN_IFACE="eth0"
CONN_PROFILE_NAME="WIFI_SECUNDARIA_AUTO" # Nombre interno para no llenar de basura el sistema
METRIC_VALUE="600"
TS_ROUTES="192.168.41.0/24"

# Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[AVISO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

# Check root
if [ "$EUID" -ne 0 ]; then
  error "Ejecuta como root (sudo)"
  exit 1
fi

echo "--- Iniciando Auto-Conexión Inteligente ---"

# 1. ENCENDER WI-FI SI ES NECESARIO
if [ "$(nmcli radio wifi)" != "enabled" ]; then
    warn "Wi-Fi apagado. Encendiendo..."
    nmcli radio wifi on
    sleep 4
else
    log "Radio Wi-Fi activo."
fi

# 2. ESCANEAR REDES "AP..."
log "Escaneando redes disponibles que empiecen por 'AP'..."

# Obtenemos lista limpia de SSIDs únicos que cumplan el patrón
# -t: modo texto, -f: campo SSID, sort -u: únicos
AVAILABLE_NETWORKS=$(nmcli -t -f SSID device wifi list | grep "^AP[0-9]" | sort -u)
NUM_NETWORKS=$(echo "$AVAILABLE_NETWORKS" | grep -v "^$" | wc -l)

TARGET_SSID=""

if [ "$NUM_NETWORKS" -eq 0 ]; then
    error "No se encontraron redes tipo 'APxxxxxx'."
    exit 1

elif [ "$NUM_NETWORKS" -eq 1 ]; then
    TARGET_SSID=$AVAILABLE_NETWORKS
    log "Se encontró una única red: $TARGET_SSID. Conectando automáticamente..."

else
    warn "Se encontraron múltiples redes ($NUM_NETWORKS):"
    
    # Convertir la lista en un array para el menú
    IFS=$'\n' read -rd '' -a NET_ARRAY <<< "$AVAILABLE_NETWORKS"
    
    # Mostrar menú
    PS3="Elige el número de la red a conectar: "
    select opt in "${NET_ARRAY[@]}"; do
        if [[ -n "$opt" ]]; then
            TARGET_SSID=$opt
            break
        else
            echo "Opción inválida, prueba otra vez."
        fi
    done
    log "Has seleccionado: $TARGET_SSID"
fi

# 3. CONFIGURAR LA CONEXIÓN (MÉTODO SEGURO)
log "Configurando perfil para '$TARGET_SSID'..."

# Borramos el perfil anterior "WIFI_SECUNDARIA_AUTO" para evitar conflictos si cambiamos de AP
if nmcli connection show "$CONN_PROFILE_NAME" &> /dev/null; then
    nmcli connection delete "$CONN_PROFILE_NAME" &> /dev/null
fi

# Crear la conexión nueva con prioridad baja (Métrica 600)
nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$CONN_PROFILE_NAME" ssid "$TARGET_SSID" \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS" \
    ipv4.route-metric "$METRIC_VALUE" > /dev/null

if [ $? -ne 0 ]; then
    error "Error al crear la configuración de red."
    exit 1
fi

# 4. CONECTAR
log "Estableciendo conexión..."
nmcli connection up "$CONN_PROFILE_NAME"

if [ $? -eq 0 ]; then
    log "¡Conectado exitosamente a $TARGET_SSID!"
else
    error "No se pudo conectar. Verifica si la señal es buena."
    # Continuamos con el resto del script por si acaso
fi

# 5. OPTIMIZACIÓN Y TAILSCALE
if command -v ethtool &> /dev/null; then
    log "Aplicando parche ethtool..."
    ethtool -K "$LAN_IFACE" rx-udp-gro-forwarding on rx-gro-list off &> /dev/null
fi

log "Levantando Tailscale..."
tailscale up --advertise-routes="$TS_ROUTES" --accept-routes

echo ""
log "Proceso finalizado. Verifica las rutas:"
route -n | grep -E "Iface|$LAN_IFACE|$WIFI_IFACE"