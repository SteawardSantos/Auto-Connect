# Auto-Connect Wi-Fi & Tailscale Setup 🚀

Este script automatiza la conexión a redes Wi-Fi específicas (con patrón `APxxxx`), asegurando que la conexión por cable (Ethernet/LAN) mantenga la prioridad para el acceso a Internet. Además, optimiza la interfaz de red y levanta **Tailscale** con rutas personalizadas.

Ideal para **Raspberry Pi** o servidores Linux que necesitan conectarse a una red Wi-Fi secundaria sin perder la estabilidad de su conexión principal por cable.

## 📋 Características

* **Escaneo Inteligente:** Busca automáticamente redes que cumplan el patrón `AP` seguido de números (ej. `AP00011381`).
* **Selector Interactivo:** Si detecta más de una red compatible, despliega un menú para elegir a cuál conectarse.
* **Protección de LAN (Route Metric):** Configura la métrica del Wi-Fi en `600` (alta) para que el sistema siga priorizando la conexión Ethernet (`eth0`) para el tráfico de Internet.
* **Optimización de Red:** Ajusta `ethtool` (UDP GRO off) para mejorar el rendimiento de **Tailscale/WireGuard**.
* **Gestión de Energía:** Activa el radio Wi-Fi automáticamente si está apagado.
* **Tailscale:** Levanta el servicio anunciando rutas locales.

## ⚙️ Requisitos

* Sistema Operativo Linux (Probado en Raspberry Pi OS / Debian / Ubuntu).
* **NetworkManager** (`nmcli`) instalado y gestionando las redes.
* **Tailscale** instalado.
* Permisos de **Root** (sudo).

Paquetes necesarios (el script intenta usar `ethtool` si existe):

```bash
sudo apt install network-manager ethtool
```

## 🚀 Instalación y Uso

* Clona este repositorio (o descarga el script):
  
  ```bash
  git clone https://github.com/SteawardSantos/Auto-Connect.git
  cd Auto-Connect
  ```

* Da permisos de ejecución:
  
  ```bash
  chmod +x auto_wifi.sh
  ```

* Ejecuta el script:
  
  ```bash
  sudo auto_wifi.sh
  ```

## 🔧 Configuración

* Puedes editar las variables al inicio del archivo `auto_wifi.sh` para adaptarlo a tu entorno:
  
  ```bash
  WIFI_PASS="TU_CONTRASEÑA"             # Contraseña para los APs
  WIFI_IFACE="wlan0"                    # Interfaz Wi-Fi
  LAN_IFACE="eth0"                      # Interfaz LAN (para optimización)
  METRIC_VALUE="600"                    # 600 = Baja prioridad (Mantiene LAN como principal)
  TS_ROUTES="192.168.41.0/24"           # Rutas a anunciar en Tailscale
  ```
  
## 📄 Licencia

* Este proyecto está bajo la Licencia MIT.
