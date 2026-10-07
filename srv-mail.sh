#!/usr/bin/env bash
###############################################################################
# srv-mail  -  POSTFIX + DOVECOT  -  instalacion automatica
# IPv4 172.19.1.40/24   IPv6 2801:BBA:1::40/64   VLAN 2 (DMZ)
# Ubuntu Server 24.04 - adaptador en PUENTE
#
# Uso:   sudo bash srv-mail.sh
#
# Deja dos buzones de prueba: jperez y mlopez, clave Giron2026
###############################################################################

set -euo pipefail

#-----------------------------------------------------------------------------
# Variables
#-----------------------------------------------------------------------------
HOSTNAME_SRV="srv-mail"
DOMINIO="nutriser.com"
IPV4="172.19.1.40"
IPV6="2801:BBA:1::40"
GW4="172.19.1.1"
GW6="2801:BBA:1::1"
DNS4="172.19.1.4"

USUARIOS=(jperez mlopez)
PASS_USUARIOS="Giron2026"

VERDE='\e[32m'; ROJO='\e[31m'; AMARILLO='\e[33m'; NC='\e[0m'
paso()  { echo -e "\n${VERDE}==> $*${NC}"; }
aviso() { echo -e "${AMARILLO}[!] $*${NC}"; }
error() { echo -e "${ROJO}[X] $*${NC}"; exit 1; }

#-----------------------------------------------------------------------------
# Comprobaciones previas
#-----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || error "Ejecuta el script con sudo:  sudo bash $0"

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
${IPV4}    email.${DOMINIO}    ${HOSTNAME_SRV}
EOF

hostnamectl set-hostname "$HOSTNAME_SRV"
timedatectl set-timezone America/Bogota

#=============================================================================
# 2 - Instalar Postfix sin asistente
#=============================================================================
paso "2/7 Instalando Postfix y Dovecot"

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

# Respuestas del asistente de Postfix, para que no pregunte nada
debconf-set-selections <<EOF
postfix postfix/main_mailer_type string Internet Site
postfix postfix/mailname string ${DOMINIO}
EOF

intentar apt-get "${APT_OPTS[@]}" update
intentar apt-get "${APT_OPTS[@]}" -y install postfix mailutils dovecot-imapd dovecot-pop3d

command -v postconf >/dev/null || error "Postfix no quedo instalado; no se aplica netplan"

#=============================================================================
# 3 - Configurar Postfix
#=============================================================================
paso "3/7 Configurando Postfix"

postconf -e "myhostname = email.${DOMINIO}"
postconf -e "mydomain = ${DOMINIO}"
postconf -e "myorigin = \$mydomain"
postconf -e "mydestination = \$myhostname, ${DOMINIO}, localhost.\$mydomain, localhost"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = all"
postconf -e "mynetworks = 127.0.0.0/8 [::1]/128 172.19.0.0/16 [2801:BBA::]/32"
postconf -e "home_mailbox = Maildir/"
postconf -e "smtpd_banner = \$myhostname ESMTP RASBI Giron"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination"

echo "--- parametros aplicados ---"
postconf -n | grep -E "myhostname|mydomain|mydestination|mynetworks|home_mailbox"

#=============================================================================
# 4 - Configurar Dovecot
#=============================================================================
paso "4/7 Configurando Dovecot"

# Archivo propio: se carga de ultimo y pisa lo anterior sin tocar los originales
cat > /etc/dovecot/conf.d/99-rasbi.conf <<'EOF'
# Configuracion RASBI Giron
mail_location = maildir:~/Maildir
disable_plaintext_auth = no
auth_mechanisms = plain login
protocols = imap pop3
listen = *, ::
EOF

doveconf -n > /dev/null || error "Error de sintaxis en Dovecot"

#=============================================================================
# 5 - Buzones de prueba
#=============================================================================
paso "5/7 Creando buzones"

for u in "${USUARIOS[@]}"; do
    if ! id "$u" >/dev/null 2>&1; then
        adduser --disabled-password --gecos "" "$u"
    fi
    echo "${u}:${PASS_USUARIOS}" | chpasswd
    mkdir -p "/home/${u}/Maildir"
    chown -R "${u}:${u}" "/home/${u}/Maildir"
    echo "  buzon ${u}@${DOMINIO} listo"
done

systemctl enable postfix dovecot
systemctl restart postfix dovecot
systemctl is-active --quiet postfix || error "Postfix no arranco: journalctl -u postfix"
systemctl is-active --quiet dovecot || error "Dovecot no arranco: journalctl -u dovecot"

#=============================================================================
# 6 - Prueba de envio local
#=============================================================================
paso "6/7 Prueba de envio"

echo "Correo de prueba generado por el script de instalacion." \
    | mail -s "Prueba RASBI Giron" "${USUARIOS[0]}@${DOMINIO}" || aviso "El envio fallo"
sleep 4
if ls "/home/${USUARIOS[0]}/Maildir/new/" >/dev/null 2>&1 && \
   [[ -n "$(ls -A "/home/${USUARIOS[0]}/Maildir/new/" 2>/dev/null)" ]]; then
    echo "Correo entregado en /home/${USUARIOS[0]}/Maildir/new/"
else
    aviso "El buzon esta vacio. Revisa: tail -30 /var/log/mail.log"
fi

ss -tlnp | grep -E ':25|:110|:143' || aviso "No se ven los puertos escuchando"

#=============================================================================
# 7 - Firewall
#=============================================================================
ufw allow 22/tcp
ufw allow 25/tcp
ufw allow 110/tcp
ufw allow 143/tcp
ufw --force enable

#=============================================================================
# 8 - Red fija (AL FINAL)
#=============================================================================
paso "7/7 Aplicando IP fija (netplan)"

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

systemctl restart postfix dovecot

#=============================================================================
# Pruebas finales
#=============================================================================
paso "Pruebas"

ip -br addr
ping -c2 -W2 "$GW4" || aviso "No responde el gateway ${GW4}"
ss -tln | grep -E ':25|:110|:143'

echo -e "\n${VERDE}Listo. srv-mail configurado en ${IPV4} / ${IPV6}${NC}"
cat <<EOF

 Clientes de correo (Thunderbird, Outlook):
   IMAP  email.${DOMINIO}  puerto 143  sin cifrado, contrasena normal
   POP3  email.${DOMINIO}  puerto 110  sin cifrado
   SMTP  email.${DOMINIO}  puerto 25   sin cifrado, sin autenticacion

 Buzones:  ${USUARIOS[0]}@${DOMINIO}  y  ${USUARIOS[1]}@${DOMINIO}
 Clave:    ${PASS_USUARIOS}

 Sin cifrado a proposito, es laboratorio. El registro MX de la zona ya apunta
 a email.${DOMINIO}; si no resuelve, revisa que srv-dns este arriba.
EOF
