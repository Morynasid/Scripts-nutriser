#!/usr/bin/env bash
###############################################################################
# srv-web  -  APACHE HTTPS + vsftpd FTPS  -  instalacion automatica
# IPv4 172.19.1.20/24   IPv6 2801:BBA:1::20/64   VLAN 2 (DMZ)
# Ubuntu Server 24.04 - adaptador en PUENTE
#
# Uso:   sudo bash srv-web.sh
#
# ANTES de ejecutar, deja en la MISMA carpeta que este script:
#     nutriser-completo.html
#     img/                      <- la carpeta con los 27 SVG y el PNG
#
# Si no estan, el script monta una pagina provisional y te avisa.
###############################################################################

set -euo pipefail

#-----------------------------------------------------------------------------
# Variables
#-----------------------------------------------------------------------------
HOSTNAME_SRV="srv-web"
DOMINIO="nutriser.com"
IPV4="172.19.1.20"
IPV6="2801:BBA:1::20"
GW4="172.19.1.1"
GW6="2801:BBA:1::1"
DNS4="172.19.1.4"

USUARIO_FTP="respaldo"
PASS_FTP="Giron2026"
RAIZ_WEB="/var/www/nutriser"

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

# Buscar la pagina en varias rutas
HTML_ORIGEN=""
IMG_ORIGEN=""
for d in "$DIR_SCRIPT" /tmp /root "$PWD"; do
    [[ -z "$HTML_ORIGEN" && -f "$d/nutriser-completo.html" ]] && HTML_ORIGEN="$d/nutriser-completo.html"
    [[ -z "$IMG_ORIGEN"  && -d "$d/img" ]]                    && IMG_ORIGEN="$d/img"
done
[[ -n "$HTML_ORIGEN" ]] && echo "HTML encontrado en: $HTML_ORIGEN" || aviso "No se encontro nutriser-completo.html"
[[ -n "$IMG_ORIGEN"  ]] && echo "Carpeta img en:     $IMG_ORIGEN"  || aviso "No se encontro la carpeta img/"

paso "Comprobando acceso a internet (necesario para apt)"
if ! getent hosts archive.ubuntu.com >/dev/null 2>&1 || \
   ! timeout 15 bash -c 'exec 3<>/dev/tcp/archive.ubuntu.com/80' 2>/dev/null; then
    error "Sin internet. Deja la VM con DHCP (como viene por defecto) y vuelve a ejecutar."
fi

#=============================================================================
# 1 - Hostname, hosts y zona horaria
#=============================================================================
paso "1/8 Hostname, /etc/hosts y zona horaria"

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
paso "2/8 Instalando Apache y vsftpd"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Acquire::ForceIPv4=true -o Acquire::Retries=3)

cambiar_espejo() {
    local f
    for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do
        [[ -f $f ]] && sed -i -E 's#http://[a-z]{2}\.archive\.ubuntu\.com#http://archive.ubuntu.com#g' "$f"
    done
    aviso "Espejo cambiado a archive.ubuntu.com"
    apt-get "${APT_OPTS[@]}" update || true
}

intentar() {
    local n
    for n in {1..10}; do
        "$@" && return 0
        aviso "apt ocupado o fallo de red, reintento $n/10 en 30 s..."
        [[ $n -eq 2 ]] && cambiar_espejo
        sleep 30
    done
    error "No se pudo ejecutar: $*"
}

intentar apt-get "${APT_OPTS[@]}" update
intentar apt-get "${APT_OPTS[@]}" -y install apache2 vsftpd lftp openssl

command -v apache2 >/dev/null || error "Apache no quedo instalado; no se aplica netplan"

a2enmod ssl headers rewrite >/dev/null

#=============================================================================
# 3 - Certificado autofirmado (lo usan Apache y vsftpd)
#=============================================================================
paso "3/8 Generando certificado"

mkdir -p /etc/ssl/nutriser
openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
  -keyout /etc/ssl/nutriser/web.key \
  -out    /etc/ssl/nutriser/web.crt \
  -subj "/C=CO/ST=Santander/L=Giron/O=RASBI/CN=web.${DOMINIO}" \
  -addext "subjectAltName=DNS:web.${DOMINIO},DNS:www.${DOMINIO},DNS:ftp.${DOMINIO},IP:${IPV4}" \
  2>/dev/null
chmod 600 /etc/ssl/nutriser/web.key

#=============================================================================
# 4 - Publicar la pagina
#=============================================================================
paso "4/8 Publicando el sitio"

mkdir -p "$RAIZ_WEB"

if [[ -n "$HTML_ORIGEN" ]]; then
    cp "$HTML_ORIGEN" "$RAIZ_WEB/index.html"
else
    aviso "Pagina provisional. Copia luego tu HTML a ${RAIZ_WEB}/index.html"
    cat > "$RAIZ_WEB/index.html" <<EOF
<!doctype html><html lang="es"><meta charset="utf-8">
<title>NutriSer</title>
<body style="font-family:sans-serif;text-align:center;padding:4rem">
<h1>RASBI - Sede Giron</h1><p>${DOMINIO} - servidor web activo</p>
<p>Falta subir nutriser-completo.html</p></body></html>
EOF
fi

if [[ -n "$IMG_ORIGEN" ]]; then
    cp -r "$IMG_ORIGEN" "$RAIZ_WEB/"
    echo "Imagenes copiadas: $(ls -1 "$RAIZ_WEB/img" | wc -l) archivos"
else
    aviso "Sin carpeta img/: la pagina va a cargar SIN logo ni ilustraciones."
    aviso "Copiala despues a ${RAIZ_WEB}/img/ y no hace falta reiniciar Apache."
fi

chown -R www-data:www-data "$RAIZ_WEB"
find "$RAIZ_WEB" -type d -exec chmod 755 {} \;
find "$RAIZ_WEB" -type f -exec chmod 644 {} \;

#=============================================================================
# 5 - Sitio virtual
#=============================================================================
paso "5/8 Configurando Apache"

cat > /etc/apache2/sites-available/nutriser-ssl.conf <<'EOF'
<VirtualHost *:443>
    ServerName  web.nutriser.com
    ServerAlias www.nutriser.com
    DocumentRoot /var/www/nutriser

    SSLEngine on
    SSLCertificateFile    /etc/ssl/nutriser/web.crt
    SSLCertificateKeyFile /etc/ssl/nutriser/web.key

    <Directory /var/www/nutriser>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>

    ErrorLog  ${APACHE_LOG_DIR}/nutriser_error.log
    CustomLog ${APACHE_LOG_DIR}/nutriser_access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName web.nutriser.com
    Redirect permanent / https://web.nutriser.com/
</VirtualHost>
EOF

a2dissite 000-default default-ssl >/dev/null 2>&1 || true
a2ensite nutriser-ssl >/dev/null
apache2ctl configtest || error "Error en la configuracion de Apache"
systemctl enable apache2
systemctl restart apache2

#=============================================================================
# 6 - vsftpd con FTPS
#=============================================================================
paso "6/8 Configurando vsftpd (FTPS)"

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
ssl_enable=YES
rsa_cert_file=/etc/ssl/nutriser/web.crt
rsa_private_key_file=/etc/ssl/nutriser/web.key
force_local_logins_ssl=YES
force_local_data_ssl=YES
ssl_tlsv1_2=YES
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

#=============================================================================
# 7 - Respaldo automatico del sitio
#=============================================================================
paso "7/8 Respaldo automatico"

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
# 8 - Firewall
#=============================================================================
ufw allow 22/tcp
ufw allow 80,443/tcp
ufw allow 21/tcp
ufw allow 40000:40100/tcp
ufw --force enable

#=============================================================================
# 9 - Red fija (AL FINAL)
#=============================================================================
paso "8/8 Aplicando IP fija (netplan)"

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
ping -c2 -W2 "$GW4" || aviso "No responde el gateway ${GW4}"

echo "HTTPS  : $(curl -s -k -o /dev/null -w '%{http_code}' https://${IPV4}/)"
echo "HTTP   : $(curl -s -k -o /dev/null -w '%{http_code}' http://${IPV4}/)   (debe ser 301)"
echo "IPv6   : $(curl -s -k -g -o /dev/null -w '%{http_code}' "https://[${IPV6}]/" || echo 'sin respuesta')"
echo "FTPS   :"
lftp -u "${USUARIO_FTP},${PASS_FTP}" "ftps://${IPV4}" \
     -e "set ssl:verify-certificate no; ls; bye" || aviso "FTPS no respondio"

echo -e "\n${VERDE}Listo. srv-web configurado en ${IPV4} / ${IPV6}${NC}"
echo "Sitio:  https://web.${DOMINIO}   (certificado autofirmado: el navegador avisa)"
echo "FTPS:   ftp.${DOMINIO}  usuario ${USUARIO_FTP}  clave ${PASS_FTP}"
[[ -z "$IMG_ORIGEN" ]] && aviso "RECUERDA copiar la carpeta img/ a ${RAIZ_WEB}/img/"
echo "Nota: el HTML carga tipografias de fonts.googleapis.com. Sin internet la"
echo "pagina se ve con la fuente por defecto del navegador."
