#!/usr/bin/env bash
###############################################################################
# srv-dns  -  BIND9  -  instalacion automatica
# IPv4 172.19.1.10/24   IPv6 2801:BBA:1::10/64   VLAN 2 (DMZ)
# Ubuntu Server 24.04 - adaptador en PUENTE
#
# Uso:   sudo bash srv-dns.sh
#
# Orden: primero se instala y configura todo con la red actual (DHCP, con
# internet) y la IP fija se aplica AL FINAL, cuando BIND ya esta funcionando.
###############################################################################

set -euo pipefail

#-----------------------------------------------------------------------------
# Variables
#-----------------------------------------------------------------------------
HOSTNAME_SRV="srv-dns"
DOMINIO="nutriser.com"
IPV4="172.19.1.10"
IPV6="2801:BBA:1::10"
GW4="172.19.1.1"
GW6="2801:BBA:1::1"
SERIAL="$(date +%Y%m%d)01"

VERDE='\e[32m'; ROJO='\e[31m'; AMARILLO='\e[33m'; NC='\e[0m'
paso()  { echo -e "\n${VERDE}==> $*${NC}"; }
aviso() { echo -e "${AMARILLO}[!] $*${NC}"; }
error() { echo -e "${ROJO}[X] $*${NC}"; exit 1; }

#-----------------------------------------------------------------------------
# Comprobaciones previas
#-----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || error "Ejecuta el script con sudo:  sudo bash $0"

# Interfaz: la que tiene la ruta por defecto ahora; si no hay, la primera != lo
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
paso "1/7 Hostname, /etc/hosts y zona horaria"

cat > /etc/hosts <<EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
${IPV4}     ${HOSTNAME_SRV}.${DOMINIO}    ${HOSTNAME_SRV}
EOF

hostnamectl set-hostname "$HOSTNAME_SRV"
timedatectl set-timezone America/Bogota

#=============================================================================
# 2 - Instalar BIND9 (todavia con la red DHCP)
#=============================================================================
paso "2/7 Instalando BIND9"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a          # evita la pantalla de "reiniciar servicios"
APT_OPTS=(-o DPkg::Lock::Timeout=600)

# En el primer arranque Ubuntu suele estar actualizando en segundo plano y
# apt esta bloqueado: se reintenta hasta 10 veces en vez de fallar
intentar() {
    local n
    for n in {1..10}; do
        "$@" && return 0
        aviso "apt ocupado o fallo de red, reintento $n/10 en 30 s..."
        sleep 30
    done
    error "No se pudo ejecutar: $*"
}

intentar apt-get "${APT_OPTS[@]}" update
intentar apt-get "${APT_OPTS[@]}" -y install bind9 bind9utils bind9-dnsutils

# Confirmar que quedo instalado ANTES de tocar la red
command -v named >/dev/null || error "BIND9 no quedo instalado; no se aplica netplan"

#=============================================================================
# 3 - Opciones globales
#=============================================================================
paso "3/7 Configurando BIND9"

cat > /etc/bind/named.conf.options <<EOF
acl redes-internas {
    127.0.0.0/8;
    ::1;
    172.19.0.0/16;
    172.16.0.0/16;
    2801:BBA::/32;
};

options {
    directory "/var/cache/bind";

    recursion yes;
    allow-query     { redes-internas; };
    allow-recursion { redes-internas; };

    forwarders { 8.8.8.8; 8.8.4.4; };
    forward only;

    dnssec-validation no;

    listen-on    { 127.0.0.1; ${IPV4}; };
    listen-on-v6 { ::1; ${IPV6}; };
};
EOF

#=============================================================================
# 4 - Zonas
#=============================================================================
cat > /etc/bind/named.conf.local <<EOF
zone "${DOMINIO}" {
    type master;
    file "/etc/bind/db.${DOMINIO}";
};

zone "1.19.172.in-addr.arpa" {
    type master;
    file "/etc/bind/db.172.19.1";
};

zone "vit.com" {
    type forward;
    forward only;
    forwarders { 172.17.1.10; };
};
EOF

# Zona directa
cat > /etc/bind/db.${DOMINIO} <<EOF
\$TTL    604800
@   IN  SOA dns.${DOMINIO}. admin.${DOMINIO}. (
            ${SERIAL}  ; Serial - subir en cada cambio
            604800      ; Refresh
            86400       ; Retry
            2419200     ; Expire
            604800 )    ; Negative TTL
;
@       IN  NS      dns.${DOMINIO}.
@       IN  MX  10  email.${DOMINIO}.
;
dns     IN  A       172.19.1.10
dns     IN  AAAA    2801:BBA:1::10
web     IN  A       172.19.1.20
web     IN  AAAA    2801:BBA:1::20
ftp     IN  A       172.19.1.20
ftp     IN  AAAA    2801:BBA:1::20
email   IN  A       172.19.1.40
email   IN  AAAA    2801:BBA:1::40
vop     IN  A       172.19.1.50
vop     IN  AAAA    2801:BBA:1::50
www     IN  CNAME   web.${DOMINIO}.
EOF

# Zona inversa
cat > /etc/bind/db.172.19.1 <<EOF
\$TTL    604800
@   IN  SOA dns.${DOMINIO}. admin.${DOMINIO}. (
            ${SERIAL} 604800 86400 2419200 604800 )
;
@       IN  NS      dns.${DOMINIO}.
;
10      IN  PTR     dns.${DOMINIO}.
20      IN  PTR     web.${DOMINIO}.
40      IN  PTR     email.${DOMINIO}.
50      IN  PTR     vop.${DOMINIO}.
EOF

#=============================================================================
# 5 - Comprobar sintaxis y arrancar BIND
#=============================================================================
paso "4/7 Comprobando sintaxis y arrancando BIND"

named-checkconf                                            || error "Error en named.conf"
named-checkzone "$DOMINIO" /etc/bind/db.${DOMINIO}         || error "Error en zona directa"
named-checkzone 1.19.172.in-addr.arpa /etc/bind/db.172.19.1 || error "Error en zona inversa"

systemctl enable named
systemctl restart named
systemctl is-active --quiet named || error "named no arranco. Revisa: journalctl -u named"

# Prueba local (la IP 172.19.1.10 todavia no existe, por eso se usa 127.0.0.1)
echo "Prueba local: web.${DOMINIO} -> $(dig @127.0.0.1 web.${DOMINIO} +short)"

#=============================================================================
# 6 - Firewall
#=============================================================================
paso "5/7 Firewall"

ufw allow 22/tcp
ufw allow 53/tcp
ufw allow 53/udp
ufw --force enable

#=============================================================================
# 7 - Red fija (AL FINAL)
#=============================================================================
paso "6/7 Aplicando IP fija (netplan)"

# Respaldar los netplan existentes (p. ej. 50-cloud-init.yaml con DHCP),
# si se dejan, la VM seguiria pidiendo DHCP ademas de la IP fija
mkdir -p /root/netplan-backup
find /etc/netplan -maxdepth 1 -name '*.yaml' ! -name '01-netcfg.yaml' \
     -exec mv {} /root/netplan-backup/ \;

# Evitar que cloud-init regenere la red en el proximo arranque
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
        addresses: [${IPV4}]
EOF
chmod 600 /etc/netplan/01-netcfg.yaml

aviso "Si estas conectado por SSH a la IP DHCP, la sesion se va a cortar aqui."
aviso "Reconecta a ${IPV4} y revisa el log (ver instrucciones de uso)."
netplan apply
sleep 3

# Reiniciar BIND para que escuche en la IP nueva
systemctl restart named

#=============================================================================
# 8 - Pruebas finales
#=============================================================================
paso "7/7 Pruebas"

ip -br addr
ping -c2 -W2 "$GW4" || aviso "No responde el gateway ${GW4} (normal si el router aun no esta montado)"

echo "web  A    : $(dig @${IPV4} web.${DOMINIO} +short)"
echo "web  AAAA : $(dig @${IPV4} web.${DOMINIO} AAAA +short)"
echo "vop  A    : $(dig @${IPV4} vop.${DOMINIO} +short)"
echo "PTR .20   : $(dig @${IPV4} -x 172.19.1.20 +short)"
echo "MX        : $(dig @${IPV4} ${DOMINIO} MX +short)"
echo "google    : $(dig @${IPV4} google.com +short | head -1)"

echo -e "\n${VERDE}Listo. srv-dns configurado.${NC}"
