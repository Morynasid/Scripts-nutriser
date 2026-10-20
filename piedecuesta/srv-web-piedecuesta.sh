#!/usr/bin/env bash
###############################################################################
# srv-web  -  APACHE HTTPS + vsftpd FTPS  -  SEDE PIEDECUESTA (fortkorp.com)
# IPv4 172.22.1.20/24   IPv6 2801:F:1::20/64   VLAN 2 (DMZ)
# Ubuntu Server - adaptador en PUENTE
#
# Uso:   sudo bash srv-web-piedecuesta.sh
#
# EL SITIO NO VA INCRUSTADO (pesa casi 10 MB por las imagenes).
# Deja junto a este script UNA de estas tres cosas:
#
#   a) la carpeta  PROYECTO-PI-desarrollo/   (ya descomprimida)
#   b) el archivo  PROYECTO-PI-desarrollo.zip
#   c) index.html + style.css + script.js + img/  sueltos
#
# O exporta una URL con el zip antes de ejecutar:
#   export URL_SITIO="https://raw.githubusercontent.com/USUARIO/REPO/main/sitio.zip"
#
# Si no encuentra nada, monta una pagina provisional y avisa.
###############################################################################

set -euo pipefail

#-----------------------------------------------------------------------------
# Variables  -  CAMBIA AQUI SI LA SEDE USA OTRAS IP
#-----------------------------------------------------------------------------
HOSTNAME_SRV="srv-web"
DOMINIO="fortkorp.com"
IPV4="172.22.1.20"
IPV6="2801:F:1::20"
GW4="172.22.1.1"
GW6="2801:F:1::1"
DNS4="172.22.1.4"            # servidor DNS de Piedecuesta

USUARIO_FTP="respaldo"
PASS_FTP="Pied2026"
RAIZ_WEB="/var/www/fortkorp"

VERDE='\e[32m'; ROJO='\e[31m'; AMARILLO='\e[33m'; NC='\e[0m'
paso()  { echo -e "\n${VERDE}==> $*${NC}"; }
aviso() { echo -e "${AMARILLO}[!] $*${NC}"; }
error() { echo -e "${ROJO}[X] $*${NC}"; exit 1; }

#-----------------------------------------------------------------------------
# Comprobaciones previas
#-----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || error "Ejecuta el script con sudo:  sudo bash $0"

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IFACE=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
[[ -n "${IFACE:-}" ]] || IFACE=$(ls /sys/class/net | grep -v '^lo$' | head -1)
[[ -n "${IFACE:-}" ]] || error "No se encontro ninguna interfaz de red"
echo "Interfaz detectada: $IFACE"

paso "Comprobando acceso a internet (necesario para apt)"
if ! getent hosts archive.ubuntu.com >/dev/null 2>&1 || \
   ! timeout 15 bash -c 'exec 3<>/dev/tcp/archive.ubuntu.com/80' 2>/dev/null; then
    error "Sin internet. Deja la VM con DHCP (como viene por defecto) y vuelve a ejecutar."
fi

#=============================================================================
# 1 - Hostname, hosts y zona horaria
#=============================================================================
paso "1/9 Hostname, /etc/hosts y zona horaria"

cat > /etc/hosts <<EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
${IPV4}    ${HOSTNAME_SRV}.${DOMINIO}    ${HOSTNAME_SRV} web.${DOMINIO} ftp.${DOMINIO}
EOF

hostnamectl set-hostname "$HOSTNAME_SRV"
timedatectl set-timezone America/Bogota

#=============================================================================
# 2 - Instalar paquetes
#=============================================================================
paso "2/9 Instalando Apache y vsftpd"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Acquire::ForceIPv4=true -o Acquire::Retries=3)

# El espejo de pais (co.archive.ubuntu.com) viene fallando, asi que pasamos al
# repositorio general ANTES de la primera descarga, no como plan B.
usar_espejo_general() {
    local f cambios=0
    for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
        [[ -f $f ]] || continue
        [[ -f "${f}.bak" ]] || cp "$f" "${f}.bak"
        if grep -qE 'https?://[a-z]{2}\.archive\.ubuntu\.com' "$f"; then
            sed -i -E 's#https?://[a-z]{2}\.archive\.ubuntu\.com#http://archive.ubuntu.com#g' "$f"
            cambios=1
        fi
    done
    if (( cambios )); then
        aviso "Espejo de pais reemplazado por archive.ubuntu.com (copia en *.bak)"
    else
        echo "El espejo ya era archive.ubuntu.com, no se toca"
    fi
}

intentar() {
    local n
    for n in {1..10}; do
        "$@" && return 0
        aviso "apt ocupado o fallo de red, reintento $n/10 en 30 s..."
        [[ $n -eq 2 ]] && { apt-get "${APT_OPTS[@]}" update || true; }
        sleep 30
    done
    error "No se pudo ejecutar: $*"
}

usar_espejo_general
intentar apt-get "${APT_OPTS[@]}" update
intentar apt-get "${APT_OPTS[@]}" -y install apache2 vsftpd lftp openssl unzip curl rsync

command -v apache2 >/dev/null || error "Apache no quedo instalado; no se aplica netplan"

a2enmod ssl headers rewrite >/dev/null

#=============================================================================
# 3 - Localizar el sitio
#=============================================================================
paso "3/9 Buscando los archivos del sitio"

ORIGEN_SITIO=""
TMP_SITIO="$(mktemp -d)"
trap 'rm -rf "$TMP_SITIO"' EXIT

# a) carpeta junto al script que contenga index.html (un nivel de profundidad)
for d in "$DIR_SCRIPT"/*/; do
    [[ -f "${d}index.html" ]] && { ORIGEN_SITIO="${d%/}"; break; }
done

# b) archivos sueltos junto al script
if [[ -z "$ORIGEN_SITIO" && -f "$DIR_SCRIPT/index.html" ]]; then
    ORIGEN_SITIO="$DIR_SCRIPT"
fi

# c) un zip junto al script
if [[ -z "$ORIGEN_SITIO" ]]; then
    for z in "$DIR_SCRIPT"/*.zip; do
        [[ -f "$z" ]] || continue
        unzip -o -q "$z" -d "$TMP_SITIO/zip" 2>/dev/null || continue
        ruta=$(find "$TMP_SITIO/zip" -maxdepth 3 -name index.html -printf '%h\n' 2>/dev/null | head -1)
        [[ -n "$ruta" ]] && { ORIGEN_SITIO="$ruta"; echo "Sitio tomado de: $z"; break; }
    done
fi

# d) descarga desde URL_SITIO
if [[ -z "$ORIGEN_SITIO" && -n "${URL_SITIO:-}" ]]; then
    echo "Descargando el sitio desde ${URL_SITIO}"
    if curl -fL --retry 3 -o "$TMP_SITIO/sitio.zip" "$URL_SITIO"; then
        unzip -o -q "$TMP_SITIO/sitio.zip" -d "$TMP_SITIO/zip" || true
        ruta=$(find "$TMP_SITIO/zip" -maxdepth 3 -name index.html -printf '%h\n' 2>/dev/null | head -1)
        [[ -n "$ruta" ]] && ORIGEN_SITIO="$ruta"
    else
        aviso "No se pudo descargar ${URL_SITIO}"
    fi
fi

[[ -n "$ORIGEN_SITIO" ]] && echo "Sitio encontrado en: $ORIGEN_SITIO" \
                         || aviso "No se encontro el sitio; se montara una pagina provisional"

#=============================================================================
# 4 - Certificado autofirmado (lo usan Apache y vsftpd)
#=============================================================================
paso "4/9 Generando certificado"

mkdir -p /etc/ssl/fortkorp
openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
  -keyout /etc/ssl/fortkorp/web.key \
  -out    /etc/ssl/fortkorp/web.crt \
  -subj "/C=CO/ST=Santander/L=Piedecuesta/O=RASBI/CN=web.${DOMINIO}" \
  -addext "subjectAltName=DNS:web.${DOMINIO},DNS:www.${DOMINIO},DNS:ftp.${DOMINIO},IP:${IPV4}" \
  2>/dev/null
chmod 600 /etc/ssl/fortkorp/web.key

#=============================================================================
# 5 - Publicar la pagina
#=============================================================================
paso "5/9 Publicando el sitio"

mkdir -p "$RAIZ_WEB"

if [[ -n "$ORIGEN_SITIO" ]]; then
    # copia el contenido, no la carpeta contenedora; omite basura del editor
    rsync -a --exclude '.vscode' --exclude '.git' --exclude '*.zip' \
          "$ORIGEN_SITIO"/ "$RAIZ_WEB"/ 2>/dev/null \
      || cp -r "$ORIGEN_SITIO"/. "$RAIZ_WEB"/
    rm -rf "$RAIZ_WEB/.vscode" "$RAIZ_WEB/.git"
else
    cat > "$RAIZ_WEB/index.html" <<EOF
<!doctype html><html lang="es"><meta charset="utf-8">
<title>FORTKORP</title>
<body style="font-family:sans-serif;text-align:center;padding:4rem">
<h1>RASBI - Sede Piedecuesta</h1><p>${DOMINIO} - servidor web activo</p>
<p>Falta subir los archivos del sitio a ${RAIZ_WEB}</p></body></html>
EOF
fi

chown -R www-data:www-data "$RAIZ_WEB"
find "$RAIZ_WEB" -type d -exec chmod 755 {} \;
find "$RAIZ_WEB" -type f -exec chmod 644 {} \;

TAM=$(stat -c%s "$RAIZ_WEB/index.html")
[[ $TAM -gt 500 ]] || error "El index.html quedo vacio o incompleto (${TAM} bytes)"
echo "index.html: ${TAM} bytes"

if [[ -d "$RAIZ_WEB/img" ]]; then
    echo "Imagenes publicadas: $(ls -1 "$RAIZ_WEB/img" | wc -l) archivos"
else
    aviso "No hay carpeta img/: la pagina se vera sin fotos ni logo"
fi

#=============================================================================
# 6 - Sitio virtual
#=============================================================================
paso "6/9 Configurando Apache"

cat > /etc/apache2/sites-available/fortkorp-ssl.conf <<EOF
<VirtualHost *:443>
    ServerName  web.${DOMINIO}
    ServerAlias www.${DOMINIO}
    DocumentRoot ${RAIZ_WEB}

    SSLEngine on
    SSLCertificateFile    /etc/ssl/fortkorp/web.crt
    SSLCertificateKeyFile /etc/ssl/fortkorp/web.key

    <Directory ${RAIZ_WEB}>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/fortkorp_error.log
    CustomLog \${APACHE_LOG_DIR}/fortkorp_access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName web.${DOMINIO}
    Redirect permanent / https://web.${DOMINIO}/
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite fortkorp-ssl >/dev/null
apache2ctl configtest || error "Error en la configuracion de Apache"
systemctl enable apache2
systemctl restart apache2

#=============================================================================
# 7 - vsftpd con FTPS
#=============================================================================
paso "7/9 Configurando vsftpd (FTPS)"

if ! id "$USUARIO_FTP" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$USUARIO_FTP"
fi
echo "${USUARIO_FTP}:${PASS_FTP}" | chpasswd
mkdir -p "/home/${USUARIO_FTP}/archivos"
chown "${USUARIO_FTP}:${USUARIO_FTP}" "/home/${USUARIO_FTP}/archivos"

[[ -f /etc/vsftpd.conf.bak ]] || cp /etc/vsftpd.conf /etc/vsftpd.conf.bak

cat > /etc/vsftpd.conf <<EOF
listen=NO
listen_ipv6=YES
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES
pam_service_name=vsftpd
secure_chroot_dir=/var/run/vsftpd/empty

# FTPS explicito
# OJO: no existe "ssl_tlsv1_2". vsftpd solo acepta ssl_tlsv1, ssl_sslv2 y
# ssl_sslv3; con ssl_tlsv1=YES, OpenSSL ya negocia TLS 1.2 o 1.3.
# Ponerlo mal hace que vsftpd arranque y muera con status=2/INVALIDARGUMENT.
ssl_enable=YES
rsa_cert_file=/etc/ssl/fortkorp/web.crt
rsa_private_key_file=/etc/ssl/fortkorp/web.key
force_local_logins_ssl=YES
force_local_data_ssl=YES
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
require_ssl_reuse=NO

# Modo pasivo
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
pasv_address=${IPV4}

userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
EOF

echo "$USUARIO_FTP" > /etc/vsftpd.userlist
mkdir -p /var/run/vsftpd/empty
systemctl enable vsftpd
systemctl restart vsftpd
sleep 2
if ! systemctl is-active --quiet vsftpd; then
    aviso "vsftpd no arranco. Error exacto:"
    vsftpd /etc/vsftpd.conf 2>&1 | head -5 || true
    aviso "Corrige /etc/vsftpd.conf y ejecuta: sudo systemctl restart vsftpd"
else
    echo "vsftpd activo y escuchando"
fi

#=============================================================================
# 8 - Respaldo automatico del sitio
#=============================================================================
paso "8/9 Respaldo automatico"

cat > /usr/local/bin/respaldo-web.sh <<EOF
#!/bin/bash
FECHA=\$(date +%Y%m%d-%H%M)
tar czf /home/${USUARIO_FTP}/archivos/web-\${FECHA}.tar.gz ${RAIZ_WEB} 2>/dev/null
chown ${USUARIO_FTP}:${USUARIO_FTP} /home/${USUARIO_FTP}/archivos/web-\${FECHA}.tar.gz
find /home/${USUARIO_FTP}/archivos -name "web-*.tar.gz" -mtime +7 -delete
EOF
chmod +x /usr/local/bin/respaldo-web.sh
/usr/local/bin/respaldo-web.sh
echo "0 2 * * * /usr/local/bin/respaldo-web.sh" | crontab -
ls -lh "/home/${USUARIO_FTP}/archivos"

#=============================================================================
# Firewall
#=============================================================================
ufw allow 22/tcp
ufw allow 80,443/tcp
ufw allow 21/tcp
ufw allow 40000:40100/tcp
ufw --force enable

#=============================================================================
# 9 - Red fija (AL FINAL)
#=============================================================================
paso "9/9 Aplicando IP fija (netplan)"

mkdir -p /root/netplan-backup
find /etc/netplan -maxdepth 1 -name '*.yaml' ! -name '01-netcfg.yaml' \
     -exec mv {} /root/netplan-backup/ \;

mkdir -p /etc/cloud/cloud.cfg.d
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

cat > /etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: no
      dhcp6: no
      accept-ra: no
      addresses:
        - ${IPV4}/24
        - ${IPV6}/64
      routes:
        - to: default
          via: ${GW4}
        - to: "::/0"
          via: ${GW6}
      nameservers:
        search: [${DOMINIO}]
        addresses: [${DNS4}]
EOF
chmod 600 /etc/netplan/01-netcfg.yaml

aviso "Si estas conectado por SSH a la IP DHCP, la sesion se va a cortar aqui."
aviso "Reconecta a ${IPV4}."
netplan apply
sleep 3

systemctl restart apache2 vsftpd

#=============================================================================
# Pruebas finales
#=============================================================================
paso "Pruebas"

ip -br addr
sleep 2
ping -c2 -W2 "$GW4" || aviso "No responde el gateway ${GW4} (si acabas de aplicar netplan, reintenta: ping ${GW4})"

echo "HTTPS  : $(curl -s -k -o /dev/null -w '%{http_code}' https://${IPV4}/)"
echo "HTTP   : $(curl -s -k -o /dev/null -w '%{http_code}' http://${IPV4}/)   (debe ser 301)"
echo "IPv6   : $(curl -s -k -g -o /dev/null -w '%{http_code}' "https://[${IPV6}]/" || echo 'sin respuesta')"
echo "FTPS   :"
timeout 25 lftp -u "${USUARIO_FTP},${PASS_FTP}" "ftps://${IPV4}" \
     -e "set net:max-retries 2; set ssl:verify-certificate no; ls; bye" || aviso "FTPS no respondio"

echo -e "\n${VERDE}Listo. srv-web de Piedecuesta en ${IPV4} / ${IPV6}${NC}"
cat <<EOF

 Sitio:  https://web.${DOMINIO}    (certificado autofirmado: el navegador avisa)
 FTPS:   ftp.${DOMINIO}   usuario ${USUARIO_FTP}   clave ${PASS_FTP}

 FALTA EN EL DNS DE PIEDECUESTA (172.22.1.4), zona fortkorp.com:
   web   IN  A     ${IPV4}
   web   IN  AAAA  ${IPV6}
   ftp   IN  A     ${IPV4}
   ftp   IN  AAAA  ${IPV6}
   www   IN  CNAME web.${DOMINIO}.
 y en la zona inversa 1.22.172.in-addr.arpa:
   20    IN  PTR   web.${DOMINIO}.
 Subir el serial del SOA y recargar:  sudo rndc reload

 NOTA SOBRE EL DISENO: la pagina carga Font Awesome desde cdnjs, las
 tipografias Poppins desde Google Fonts y un mapa embebido de Google Maps.
 Sin salida a internet se vera con la fuente por defecto, sin iconos y con el
 mapa en blanco. El resto del sitio funciona igual.
EOF
