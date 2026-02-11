#!/bin/bash

# ==========================================
#      CONFIGURACIÓN DEL NODO (EDITAR)
# ==========================================
# "AUTO" para escanear la red y buscar un ID libre
# O un número fijo (1, 2, 3...) para forzarlo
NODE_ID="AUTO" 

# ==========================================
#           VARIABLES DEL SISTEMA
# ==========================================
# El prefijo de la IP virtual (se completará con NODE_ID)
VIRTUAL_SUBNET="10.200.0"
TARGET_REAL_IP="192.168.41.1"       # IP Real del dispositivo local
WIFI_PASS="SN2008@+"                # Contraseña del AP
WIFI_IFACE="wlan0"
LAN_IFACE="eth0"
CONN_PROFILE_NAME="WIFI_SECUNDARIA_NAT"
METRIC_VALUE="600"                  # 600 = Prioridad baja (Protege LAN)

# ==========================================
#               FUNCIONES
# ==========================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[AVISO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

if [ "$EUID" -ne 0 ]; then
  error "Este script requiere sudo."
  exit 1
fi

# Detección de OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_LIKE=$ID_LIKE
else
    OS="unknown"
    OS_LIKE="unknown"
fi

log "Sistema detectado: $PRETTY_NAME ($OS)"

install_pkg() {
    local PKG=$1
    if [[ "$OS" == "cachyos" || "$OS_LIKE" == *"arch"* ]]; then
        if ! pacman -Qi "$PKG" &> /dev/null; then
            log "Instalando $PKG con pacman..."
            pacman -Sy --noconfirm --needed "$PKG" > /dev/null
        fi
    elif [[ "$OS_LIKE" == *"debian"* ]]; then
        if ! dpkg -s "$PKG" &> /dev/null; then
            log "Instalando $PKG con apt..."
            DEBIAN_FRONTEND=noninteractive apt-get update && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" > /dev/null
        fi
    else
        warn "Gestor de paquetes desconocido. Intenta instalar $PKG manualmente."
    fi
}

# Función para escanear y detectar ID
get_auto_node_id() {
    log "Iniciando detección automática de ID de nodo..."
    
    # Instalar nmap si es necesario para el escaneo
    install_pkg "nmap"

    local USED_IDS=()
    
    # 1. Escanear Tailscale (si está activo)
    if command -v tailscale &> /dev/null; then
        log "Verificando peers en Tailscale..."
        # Extrae IPs 10.200.0.X y obtiene la X
        local TS_IPS=$(tailscale status 2>/dev/null | grep "$VIRTUAL_SUBNET" | grep -oE "$VIRTUAL_SUBNET\.[0-9]+" | awk -F. '{print $4}')
        for id in $TS_IPS; do
            USED_IDS+=($id)
        done
    fi

    # 2. Escanear Subred Local (LAN/WiFi)
    # Detectar subred actual
    local CURRENT_IP_CIDR=$(ip -o -f inet addr show | grep -v "127.0.0.1" | awk '{print $4}' | head -n 1)
    if [ -n "$CURRENT_IP_CIDR" ]; then
        log "Escaneando subred local ($CURRENT_IP_CIDR) para evitar conflictos..."
        # Escaneo rápido de ping (-sn)
        local SCAN_OUT=$(nmap -sn -n "$CURRENT_IP_CIDR" -oG - | grep "Status: Up")
        # Extraer últimos octetos de las IPs encontradas
        local LOCAL_IPS=$(echo "$SCAN_OUT" | awk '{print $2}' | awk -F. '{print $4}')
        for id in $LOCAL_IPS; do
            USED_IDS+=($id)
        done
    else
        warn "No se pudo detectar subred local para escanear."
    fi

    # 3. Buscar primer ID libre (1-254)
    for i in {1..254}; do
        if [[ ! " ${USED_IDS[@]} " =~ " ${i} " ]]; then
            echo "$i"
            return
        fi
    done
    
    echo "FAIL"
}

# Determinación del NODE_ID
if [ "$NODE_ID" == "AUTO" ]; then
    DETECTED_ID=$(get_auto_node_id)
    if [ "$DETECTED_ID" == "FAIL" ] || [ -z "$DETECTED_ID" ]; then
        error "No se pudo determinar un ID libre. Usando fallback ID=99"
        NODE_ID="99"
    else
        NODE_ID="$DETECTED_ID"
        log "ID de nodo asignado automáticamente: $NODE_ID"
    fi
fi

VIRTUAL_IP="${VIRTUAL_SUBNET}.${NODE_ID}"    # IP Fantasma calculada

echo "--- Iniciando Configuración Automática (v8 - Arch/CachyOS Support) ---"
echo "Nodo: $NODE_ID | IP Virtual: $VIRTUAL_IP | OS: $OS"

# ------------------------------------------
# 1. GESTIÓN INTELIGENTE DEL WI-FI
# ------------------------------------------
log "Verificando conectividad Wi-Fi..."

# Encender radio si está apagado
if command -v nmcli &> /dev/null; then
    if [ "$(nmcli radio wifi)" != "enabled" ]; then
        warn "Radio Wi-Fi apagado. Encendiendo..."
        nmcli radio wifi on
        sleep 4
    fi

    # Verificar si ya estamos conectados al perfil correcto
    CURRENT_CON=$(nmcli -t -f NAME connection show --active | grep "$CONN_PROFILE_NAME")

    if [ "$CURRENT_CON" == "$CONN_PROFILE_NAME" ]; then
        log "Conexión Wi-Fi correcta detectada. Asegurando métrica..."
        nmcli connection modify "$CONN_PROFILE_NAME" ipv4.route-metric "$METRIC_VALUE"
    else
        log "Buscando red APxxxx..."
        # Busca la primera red que cumpla el patrón
        TARGET_SSID=$(nmcli -t -f SSID device wifi list | grep "^AP[0-9]" | head -n 1)
        
        if [ -z "$TARGET_SSID" ]; then
            warn "No se encontraron redes 'APxxxx'. Continuando con la configuración local..."
        else
            log "Red encontrada: $TARGET_SSID. Configurando..."
            
            # Limpieza preventiva
            if nmcli connection show "$CONN_PROFILE_NAME" &> /dev/null; then
                nmcli connection delete "$CONN_PROFILE_NAME" &> /dev/null
            fi

            # Crear conexión segura
            nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$CONN_PROFILE_NAME" ssid "$TARGET_SSID" \
                wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS" \
                ipv4.route-metric "$METRIC_VALUE" > /dev/null
                
            nmcli connection up "$CONN_PROFILE_NAME"
        fi
    fi
else
    warn "nmcli no encontrado. Saltando configuración Wi-Fi."
fi

# ------------------------------------------
# 2. OPTIMIZACIÓN Y KERNEL (Idempotente)
# ------------------------------------------
log "Aplicando parches de kernel..."

# Optimización Ethtool
install_pkg "ethtool"
if command -v ethtool &> /dev/null; then
    ethtool -K "$LAN_IFACE" rx-udp-gro-forwarding on rx-gro-list off &> /dev/null || true
fi

# IP Forwarding (Sobrescritura limpia)
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-tailscale-nat.conf
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-tailscale-nat.conf
sysctl -p /etc/sysctl.d/99-tailscale-nat.conf &> /dev/null

# ------------------------------------------
# 3. IP VIRTUAL (Loopback)
# ------------------------------------------
if ip addr show lo | grep -q "$VIRTUAL_IP"; then
    log "IP Virtual ya configurada."
else
    log "Asignando IP Virtual $VIRTUAL_IP..."
    ip addr add "$VIRTUAL_IP/32" dev lo
fi

# ------------------------------------------
# 4. FIREWALL & DNS CHECK
# ------------------------------------------
log "Configurando reglas NAT..."

# Limpieza de reglas NAT previas
iptables -t nat -F

# Reglas de redirección
iptables -t nat -A PREROUTING -d "$VIRTUAL_IP" -j DNAT --to-destination "$TARGET_REAL_IP"
iptables -t nat -A POSTROUTING -d "$TARGET_REAL_IP" -j MASQUERADE

# Persistencia de reglas (Multi-Distro)
if [[ "$OS" == "cachyos" || "$OS_LIKE" == *"arch"* ]]; then
    # Arch Linux / CachyOS way
    install_pkg "iptables" # Asegurar iptables
    log "Guardando reglas en /etc/iptables/iptables.rules (Arch)..."
    mkdir -p /etc/iptables
    iptables-save -f /etc/iptables/iptables.rules
    systemctl enable --now iptables
else
    # Debian / Ubuntu way
    if ! dpkg -s iptables-persistent &> /dev/null; then
        log "El paquete 'iptables-persistent' falta. Intentando instalar..."
        
        # TRUCO: Si el DNS está roto por Tailscale, intentamos arreglarlo temporalmente
        if ! ping -c 1 google.com &> /dev/null; then
            warn "DNS parece roto. Usando parche temporal 8.8.8.8..."
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
        fi
        
        install_pkg "iptables-persistent"
    fi
    netfilter-persistent save &> /dev/null
fi

# ------------------------------------------
# 5. TAILSCALE (CON FIX DE DNS)
# ------------------------------------------
log "Aplicando configuración final de Tailscale..."

# AQUI ESTA EL FIX: --accept-dns=false
# Esto evita que Tailscale rompa la resolución de nombres local/internet
if command -v tailscale &> /dev/null; then
    tailscale up \
        --advertise-routes="${VIRTUAL_IP}/32" \
        --accept-routes \
        --accept-dns=false \
        --reset
else
    error "Tailscale no está instalado. Por favor instálalo manualmente."
fi

echo ""
log "✅ INSTALACIÓN COMPLETADA CORRECTAMENTE"
echo "-----------------------------------------------------"
echo " 📡 Nodo ID:         $NODE_ID"
echo " 🔗 IP de Acceso:    $VIRTUAL_IP"
echo " 🎯 Destino Real:    $TARGET_REAL_IP"
echo " 🌍 DNS Fix:         ACTIVADO (--accept-dns=false)"
echo "-----------------------------------------------------"