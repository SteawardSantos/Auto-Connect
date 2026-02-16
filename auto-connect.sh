#!/bin/bash

# ==========================================
#      CONFIGURACIÓN DEL NODO (EDITAR)
# ==========================================
# Cambia este ID en cada Raspberry (1, 2, 3...)
NODE_ID="1" 

# ==========================================
#           VARIABLES DEL SISTEMA
# ==========================================
VIRTUAL_IP="10.200.0.${NODE_ID}"    # IP Fantasma para acceder a este nodo
TARGET_REAL_IP="192.168.41.1"       # IP Real del dispositivo local
WIFI_PASS="SN2008@+"                # Contraseña del AP
WIFI_IFACE="wlan0"
LAN_IFACE="eth0"
CONN_PROFILE_NAME="WIFI_SECUNDARIA_NAT"
METRIC_VALUE="600"                  # 600 = Prioridad baja (Protege LAN)
MTU_VALUE="1350"                    # MTU conservador para prevenir fragmentación

# ==========================================
#               FUNCIONES
# ==========================================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[AVISO] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }
debug() { echo -e "${BLUE}[DEBUG] $1${NC}"; }

if [ "$EUID" -ne 0 ]; then
  error "Este script requiere sudo."
  exit 1
fi

echo "========================================================"
echo "  Auto-Config RaspberryPi → Tailscale Bridge (v8)"
echo "========================================================"
echo "Nodo: $NODE_ID | IP Virtual: $VIRTUAL_IP"
echo ""

# ==========================================
#       PRE-FLIGHT CHECKS (NUEVO)
# ==========================================
log "Ejecutando validaciones de red..."

# ------------------------------------------
# 1A. VERIFICAR ESTADO IPv4 EN LAN (eth0)
# ------------------------------------------
debug "Verificando conectividad IPv4 en $LAN_IFACE..."

# Obtener IP actual de eth0 (IPv4)
ETH0_IPV4=$(ip -4 addr show "$LAN_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ -z "$ETH0_IPV4" ]; then
    warn "⚠️  $LAN_IFACE no tiene dirección IPv4 asignada."
    
    # Verificar si tiene IPv6 (indicador de DHCP parcial fallido)
    ETH0_IPV6=$(ip -6 addr show "$LAN_IFACE" | grep -oP '(?<=inet6\s)([0-9a-f:]+)(?=/\d+\s+scope\s+global)')
    
    if [ -n "$ETH0_IPV6" ]; then
        error "Detectado problema conocido: IPv6 funcional pero IPv4 fallido en $LAN_IFACE"
        echo ""
        echo "Diagnóstico automático:"
        echo "  - IPv6: ✅ $ETH0_IPV6"
        echo "  - IPv4: ❌ No asignada"
        echo ""
        
        # Verificar logs de DHCP
        DHCP_ERRORS=$(journalctl -u NetworkManager --since "10 minutes ago" 2>/dev/null | grep -i "dhcp\|timeout\|canceled" | tail -5)
        
        if [ -n "$DHCP_ERRORS" ]; then
            warn "Errores DHCP detectados en los últimos 10 minutos:"
            echo "$DHCP_ERRORS"
            echo ""
        fi
        
        # Intentar descubrir red con ARP (como en el RCA)
        warn "Intentando descubrir red local con ARP sniffing (5 segundos)..."
        timeout 5 tcpdump -i "$LAN_IFACE" -n arp 2>/dev/null | tee /tmp/arp_scan.log &
        TCPDUMP_PID=$!
        sleep 6
        
        # Analizar resultados
        DISCOVERED_NETWORK=$(grep -oP 'tell \K\d+\.\d+\.\d+\.\d+' /tmp/arp_scan.log | head -1)
        
        if [ -n "$DISCOVERED_NETWORK" ]; then
            warn "Red detectada vía ARP: $DISCOVERED_NETWORK"
            # Extraer los primeros 3 octetos para sugerir subnet
            SUBNET_BASE=$(echo "$DISCOVERED_NETWORK" | cut -d. -f1-3)
            warn "Subnet probable: ${SUBNET_BASE}.0/24"
            echo ""
            echo "SOLUCIÓN RECOMENDADA:"
            echo "  1. Configurar IP estática en esta subnet:"
            echo "     sudo nmcli connection modify \"Wired connection 1\" \\"
            echo "       ipv4.method manual \\"
            echo "       ipv4.addresses ${SUBNET_BASE}.222/24 \\"
            echo "       ipv4.gateway ${SUBNET_BASE}.1 \\"
            echo "       ipv4.dns \"8.8.8.8,1.1.1.1\""
            echo ""
            echo "  2. Reiniciar conexión:"
            echo "     sudo nmcli connection down \"Wired connection 1\" && \\"
            echo "     sudo nmcli connection up \"Wired connection 1\""
            echo ""
            error "Abortando script. Configura IPv4 manualmente primero."
            exit 1
        else
            error "No se pudo detectar red activa. Verifica el cable Ethernet."
            echo ""
            echo "Comandos de diagnóstico manual:"
            echo "  - Ver configuración: ip addr show $LAN_IFACE"
            echo "  - Ver logs DHCP: journalctl -u NetworkManager -n 50"
            echo "  - Sniffing ARP: sudo tcpdump -i $LAN_IFACE -n arp"
            exit 1
        fi
    else
        error "$LAN_IFACE no tiene IPv4 ni IPv6. Verifica conexión física."
        exit 1
    fi
else
    log "✅ IPv4 detectada en $LAN_IFACE: $ETH0_IPV4"
fi

# ------------------------------------------
# 1B. DETECTAR CONFIGURACIÓN MANUAL (NUEVO)
# ------------------------------------------
LAN_CONNECTION=$(nmcli -t -f NAME,DEVICE connection show --active | grep "$LAN_IFACE" | cut -d: -f1)

if [ -n "$LAN_CONNECTION" ]; then
    IPV4_METHOD=$(nmcli -t -f ipv4.method connection show "$LAN_CONNECTION" | cut -d: -f2)
    
    if [ "$IPV4_METHOD" == "manual" ]; then
        log "✅ Configuración manual detectada en $LAN_IFACE (se respetará)"
        debug "Conexión: $LAN_CONNECTION | Método: $IPV4_METHOD"
        MANUAL_CONFIG=true
    else
        log "Método IPv4 en $LAN_IFACE: $IPV4_METHOD"
        MANUAL_CONFIG=false
    fi
fi

# ------------------------------------------
# 1C. AJUSTE DE MTU (PREVENCIÓN FRAGMENTACIÓN)
# ------------------------------------------
CURRENT_MTU=$(cat /sys/class/net/$LAN_IFACE/mtu)

if [ "$CURRENT_MTU" -ne "$MTU_VALUE" ]; then
    log "Ajustando MTU de $LAN_IFACE: $CURRENT_MTU → $MTU_VALUE (previene fragmentación)"
    ip link set dev "$LAN_IFACE" mtu "$MTU_VALUE"
    
    # Hacer persistente en NetworkManager
    if [ -n "$LAN_CONNECTION" ]; then
        nmcli connection modify "$LAN_CONNECTION" 802-3-ethernet.mtu "$MTU_VALUE" 2>/dev/null || true
    fi
else
    log "✅ MTU de $LAN_IFACE ya configurado: $MTU_VALUE"
fi

# ------------------------------------------
# 2. GESTIÓN INTELIGENTE DEL WI-FI
# ------------------------------------------
log "Verificando conectividad Wi-Fi..."

# Encender radio si está apagado
if [ "$(nmcli radio wifi)" != "enabled" ]; then
    warn "Radio Wi-Fi apagado. Encendiendo..."
    nmcli radio wifi on
    sleep 4
fi

# Verificar si ya estamos conectados al perfil correcto
CURRENT_CON=$(nmcli -t -f NAME connection show --active | grep "$CONN_PROFILE_NAME")

if [ "$CURRENT_CON" == "$CONN_PROFILE_NAME" ]; then
    log "✅ Conexión Wi-Fi correcta detectada. Asegurando métrica..."
    nmcli connection modify "$CONN_PROFILE_NAME" ipv4.route-metric "$METRIC_VALUE"
else
    log "Buscando red APxxxx..."
    # Busca la primera red que cumpla el patrón
    TARGET_SSID=$(nmcli -t -f SSID device wifi list | grep "^AP[0-9]" | head -n 1)
    
    if [ -z "$TARGET_SSID" ]; then
        error "No se encontraron redes compatibles con patrón AP[0-9]."
        exit 1
    fi

    log "Red encontrada: $TARGET_SSID. Configurando..."
    
    # Limpieza preventiva
    if nmcli connection show "$CONN_PROFILE_NAME" &> /dev/null; then
        nmcli connection delete "$CONN_PROFILE_NAME" &> /dev/null
    fi

    # Crear conexión segura con métrica baja (no interferir con LAN)
    nmcli connection add type wifi ifname "$WIFI_IFACE" con-name "$CONN_PROFILE_NAME" ssid "$TARGET_SSID" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PASS" \
        ipv4.route-metric "$METRIC_VALUE" \
        ipv6.method "ignore" > /dev/null
        
    nmcli connection up "$CONN_PROFILE_NAME"
    
    if [ $? -eq 0 ]; then
        log "✅ Conectado a $TARGET_SSID"
    else
        warn "No se pudo conectar a $TARGET_SSID (no es crítico si LAN funciona)"
    fi
fi

# ------------------------------------------
# 3. OPTIMIZACIÓN Y KERNEL (Idempotente)
# ------------------------------------------
log "Aplicando parches de kernel..."

# Optimización Ethtool (GRO para bridge)
if command -v ethtool &> /dev/null; then
    ethtool -K "$LAN_IFACE" rx-udp-gro-forwarding on rx-gro-list off &> /dev/null || true
fi

# IP Forwarding (Sobrescritura limpia)
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-tailscale-nat.conf
echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/99-tailscale-nat.conf

# Optimizaciones adicionales para Raspberry Pi como bridge
echo "net.ipv4.conf.all.rp_filter = 0" >> /etc/sysctl.d/99-tailscale-nat.conf
echo "net.ipv4.conf.$LAN_IFACE.rp_filter = 0" >> /etc/sysctl.d/99-tailscale-nat.conf
echo "net.ipv4.conf.all.accept_source_route = 1" >> /etc/sysctl.d/99-tailscale-nat.conf

sysctl -p /etc/sysctl.d/99-tailscale-nat.conf &> /dev/null

# ------------------------------------------
# 4. IP VIRTUAL (Loopback)
# ------------------------------------------
if ip addr show lo | grep -q "$VIRTUAL_IP"; then
    log "✅ IP Virtual ya configurada."
else
    log "Asignando IP Virtual $VIRTUAL_IP al loopback..."
    ip addr add "$VIRTUAL_IP/32" dev lo
fi

# ------------------------------------------
# 5. FIREWALL & DNS CHECK
# ------------------------------------------
log "Configurando reglas NAT..."

# Limpieza de reglas NAT previas
iptables -t nat -F

# Reglas de redirección (DNAT Virtual → Real)
iptables -t nat -A PREROUTING -d "$VIRTUAL_IP" -j DNAT --to-destination "$TARGET_REAL_IP"
iptables -t nat -A POSTROUTING -d "$TARGET_REAL_IP" -j MASQUERADE

# Regla adicional: MASQUERADE para tráfico saliente de la subnet local
iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE

# Persistencia de reglas
if ! dpkg -s iptables-persistent &> /dev/null; then
    log "Instalando 'iptables-persistent'..."
    
    # TRUCO: Si el DNS está roto por Tailscale, intentamos arreglarlo temporalmente
    if ! ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        warn "Conectividad limitada. Usando DNS público temporal..."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    fi
    
    DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null
fi
netfilter-persistent save &> /dev/null

# ------------------------------------------
# 6. TAILSCALE (CON FIX DE DNS)
# ------------------------------------------
log "Aplicando configuración final de Tailscale..."

# Verificar que tailscale esté instalado
if ! command -v tailscale &> /dev/null; then
    error "Tailscale no está instalado. Instálalo primero:"
    echo "  curl -fsSL https://tailscale.com/install.sh | sh"
    exit 1
fi

# --accept-dns=false: Evita que Tailscale rompa DNS local/internet
tailscale up \
    --advertise-routes="${VIRTUAL_IP}/32" \
    --accept-routes \
    --accept-dns=false \
    --reset

echo ""
echo "========================================================"
log "✅ INSTALACIÓN COMPLETADA CORRECTAMENTE"
echo "========================================================"
echo " � Nodo ID:          $NODE_ID"
echo " 🔗 IP Virtual:       $VIRTUAL_IP (vía Tailscale)"
echo " 🎯 Destino Real:     $TARGET_REAL_IP"
echo " 📡 Interfaz LAN:     $LAN_IFACE ($ETH0_IPV4)"
echo " 🛡️  MTU:             $MTU_VALUE (anti-fragmentación)"
echo " 🌍 DNS Fix:          ACTIVADO (--accept-dns=false)"
echo " ⚙️  Config Manual:    $([ "$MANUAL_CONFIG" == "true" ] && echo "SÍ (respetada)" || echo "NO")"
echo "========================================================"
echo ""
log "El nodo está listo para funcionar como bridge Tailscale."
log "Para verificar rutas anunciadas: tailscale status"