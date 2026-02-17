#!/bin/bash

# ========================================================
#   Tailscale Bridge Node Report Generator
#   Genera un reporte CSV de todos los nodos rpi-pt
# ========================================================

OUTPUT_FILE="nodes_report.csv"
VIRTUAL_IP_BASE="10.200.0"

# Colores para CLI
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}[INFO] Escaneando red Tailscale...${NC}"

# Verificar si Tailscale está accesible
if ! tailscale status --json &>/dev/null; then
    echo "Error: Tailscale no está en ejecución o no hay acceso."
    exit 1
fi

# Crear cabecera CSV
echo "ID,Hostname,Tailscale_IP,Virtual_IP,Status" > "$OUTPUT_FILE"

# Obtener lista ordenada de nodos que coinciden con el patrón *-rpi-pt
# Usamos el DNSName (parte antes del primer punto) para el orden alfabético
ALL_NODES=$(tailscale status --json | grep -oP '"DNSName":\s*"\K[^."]+' | grep "\-rpi\-pt" | sort -u)

if [ -z "$ALL_NODES" ]; then
    echo "No se encontraron nodos con el patrón *-rpi-pt"
    exit 0
fi

INDEX=1
while read -r node; do
    # Obtener la IP de Tailscale para este nodo
    # Buscamos en el status el nodo por su nombre y extraemos su primera IP
    TS_IP=$(tailscale status | grep "$node" | awk '{print $1}' | head -1)
    
    # Obtener el estado (online/offline)
    STATUS=$(tailscale status | grep "$node" | grep -q "offline" && echo "Offline" || echo "Online")
    
    # La IP virtual calculada por el script basado en posición alfabética
    VIRTUAL_IP="${VIRTUAL_IP_BASE}.${INDEX}"
    
    # Escribir al CSV
    echo "${INDEX},${node},${TS_IP},${VIRTUAL_IP},${STATUS}" >> "$OUTPUT_FILE"
    
    echo -e "${GREEN}  [✓] Nodo ${INDEX}: ${node} (${VIRTUAL_IP})${NC}"
    
    INDEX=$((INDEX + 1))
done <<< "$ALL_NODES"

echo ""
echo -e "${BLUE}Reporte generado con éxito: ${OUTPUT_FILE}${NC}"
echo "--------------------------------------------------------"
column -t -s, "$OUTPUT_FILE"
