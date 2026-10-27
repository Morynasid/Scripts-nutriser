#!/usr/bin/env bash
###############################################################################
# srv-mail  -  POSTFIX + DOVECOT (entrega por LMTP)  -  SEDE GIRON
# IPv4 172.19.1.40/24   IPv6 2801:BBA:1::40/64   VLAN 2 (DMZ)
# Ubuntu Server - adaptador en PUENTE
#
# Uso:   sudo bash srv-mail.sh
#
# POR QUE LMTP:
#   Antes Postfix escribia el Maildir por su cuenta (home_mailbox) y Dovecot
#   lo leia despues. Si los indices de Dovecot quedaban desfasados, el correo
#   estaba en disco pero el cliente veia la bandeja vacia -- sin ningun error.
#   Con LMTP, Postfix le pasa el mensaje a Dovecot y es Dovecot quien escribe
#   y lo indexa en el mismo acto. No puede haber desfase.
#
# El script termina enviando un correo de prueba de verdad y comprobando que
# aparece en INBOX. Si no aparece, falla y muestra el diagnostico, en vez de
# dejarte descubrirlo al configurar Thunderbird.
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
paso "1/9 Hostname, /etc/hosts y zona horaria"

cat > /etc/hosts <<EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
${IPV4}    email.${DOMINIO}    ${HOSTNAME_SRV}
EOF

hostnamectl set-hostname "$HOSTNAME_SRV"
timedatectl set-timezone America/Bogota

#=============================================================================
# 2 - Instalar paquetes
#=============================================================================
paso "2/9 Instalando Postfix y Dovecot"

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

# Respuestas del asistente de Postfix, para que no pregunte nada
debconf-set-selections <<EOF
postfix postfix/main_mailer_type string Internet Site
postfix postfix/mailname string ${DOMINIO}
EOF

usar_espejo_general
intentar apt-get "${APT_OPTS[@]}" update
intentar apt-get "${APT_OPTS[@]}" -y install \
    postfix mailutils dovecot-core dovecot-imapd dovecot-pop3d dovecot-lmtpd

command -v postconf >/dev/null || error "Postfix no quedo instalado; no se aplica netplan"
command -v doveconf >/dev/null || error "Dovecot no quedo instalado; no se aplica netplan"

DV=$(dovecot --version 2>/dev/null | awk '{print $1}')
DV_MAJ=${DV%%.*}; DV_RESTO=${DV#*.}; DV_MIN=${DV_RESTO%%.*}
echo "Dovecot detectado: ${DV}"

#=============================================================================
# 3 - Usuarios y buzones (ANTES de arrancar Dovecot)
#=============================================================================
paso "3/9 Creando usuarios y buzones"

systemctl stop dovecot 2>/dev/null || true

for u in "${USUARIOS[@]}"; do
    if ! id "$u" >/dev/null 2>&1; then
        adduser --disabled-password --gecos "" "$u"
    fi
    echo "${u}:${PASS_USUARIOS}" | chpasswd

    # Maildir con su estructura completa
    mkdir -p "/home/${u}/Maildir"/{cur,new,tmp}

    # Borrar indices de ejecuciones anteriores: si el script ya corrio con una
    # configuracion rota, los indices viejos hacen que Dovecot informe la
    # bandeja vacia aunque los correos esten en new/.
    rm -f  "/home/${u}/Maildir"/dovecot.* "/home/${u}/Maildir"/dovecot-* \
           "/home/${u}/Maildir"/subscriptions 2>/dev/null || true

    chown -R "${u}:${u}" "/home/${u}"
    chmod 700 "/home/${u}/Maildir"
    echo "  buzon ${u}@${DOMINIO} listo"
done

#=============================================================================
# 4 - Configurar Dovecot
#=============================================================================
paso "4/9 Configurando Dovecot"

# El socket LMTP vive dentro del chroot de Postfix para que Postfix lo alcance.
LMTP_SOCK="/var/spool/postfix/private/dovecot-lmtp"

if (( DV_MAJ > 2 || ( DV_MAJ == 2 && DV_MIN >= 4 ) )); then
cat > /etc/dovecot/conf.d/99-rasbi.conf <<EOF
# ===== Configuracion RASBI Giron - Dovecot 2.4 =====
# En 2.4 "mail_location" ya no existe: se partio en mail_driver + mail_path,
# y "disable_plaintext_auth" paso a llamarse "auth_allow_cleartext".
mail_driver = maildir
mail_path = ~/Maildir

# CLAVE: vaciar mail_inbox_path. El paquete de Ubuntu lo deja en
# /var/mail/%{user}, lo que saca INBOX del Maildir y lo manda a un directorio
# root:mail donde el usuario no puede escribir. Sintoma: el cliente autentica
# bien pero al abrir la bandeja devuelve "[SERVERBUG] Internal error" y el log
# dice "Mailbox INBOX: Failed to autocreate mailbox: Permission denied".
mail_inbox_path =

auth_allow_cleartext = yes
auth_mechanisms = plain login

protocols {
  imap = yes
  pop3 = yes
  lmtp = yes
}

service lmtp {
  unix_listener ${LMTP_SOCK} {
    mode  = 0600
    user  = postfix
    group = postfix
  }
}
EOF
else
cat > /etc/dovecot/conf.d/99-rasbi.conf <<EOF
# ===== Configuracion RASBI Giron - Dovecot 2.3 =====
mail_location = maildir:~/Maildir
disable_plaintext_auth = no
auth_mechanisms = plain login
protocols = imap pop3 lmtp

service lmtp {
  unix_listener ${LMTP_SOCK} {
    mode  = 0600
    user  = postfix
    group = postfix
  }
}
EOF
fi

if ! doveconf -n > /dev/null 2>&1; then
    echo "--- salida de doveconf ---"
    doveconf -n || true
    error "Error de sintaxis en Dovecot (ver arriba)"
fi
echo "Configuracion de Dovecot valida"

systemctl enable dovecot >/dev/null
systemctl restart dovecot
sleep 3
systemctl is-active --quiet dovecot || error "Dovecot no arranco: journalctl -u dovecot -n 30"

#=============================================================================
# 5 - Configurar Postfix para entregar por LMTP
#=============================================================================
paso "5/9 Configurando Postfix"

postconf -e "myhostname = email.${DOMINIO}"
postconf -e "mydomain = ${DOMINIO}"
postconf -e "myorigin = \$mydomain"
postconf -e "mydestination = \$myhostname, ${DOMINIO}, localhost.\$mydomain, localhost"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = all"
postconf -e "mynetworks = 127.0.0.0/8 [::1]/128 172.19.0.0/16 [2801:BBA::]/32"
postconf -e "smtpd_banner = \$myhostname ESMTP RASBI Giron"
postconf -e "smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination"

# La entrega la hace Dovecot, no el agente local de Postfix.
postconf -e "mailbox_transport = lmtp:unix:private/dovecot-lmtp"
postconf -X home_mailbox       2>/dev/null || true
postconf -X mailbox_command    2>/dev/null || true

echo "--- parametros aplicados ---"
postconf -n | grep -E "myhostname|mydestination|mynetworks|mailbox_transport"

systemctl enable postfix >/dev/null
systemctl restart postfix
sleep 2
systemctl is-active --quiet postfix || error "Postfix no arranco: journalctl -u postfix -n 30"

# El socket LMTP tiene que existir o no se entrega nada
if [[ ! -S "$LMTP_SOCK" ]]; then
    aviso "No existe el socket ${LMTP_SOCK}"
    aviso "Reiniciando Dovecot para crearlo..."
    systemctl restart dovecot
    sleep 3
fi
[[ -S "$LMTP_SOCK" ]] || error "El socket LMTP no se creo. Revisa: doveconf -n | grep -A6 'service lmtp'"
echo "Socket LMTP presente: ${LMTP_SOCK}"

#=============================================================================
# 6 - Carpetas estandar para Thunderbird
#=============================================================================
paso "6/9 Creando carpetas (Sent, Drafts, Trash, Junk)"

for u in "${USUARIOS[@]}"; do
    for carpeta in Sent Drafts Trash Junk; do
        doveadm mailbox create -u "$u" "$carpeta" 2>/dev/null || true
    done
    doveadm mailbox subscribe -u "$u" INBOX Sent Drafts Trash Junk 2>/dev/null || true
    echo "  carpetas de ${u}: $(doveadm mailbox list -u "$u" 2>/dev/null | tr '\n' ' ')"
done

#=============================================================================
# 7 - PRUEBA REAL DE PUNTA A PUNTA
#=============================================================================
paso "7/9 Enviando un correo de prueba y comprobando que llega"

DESTINO="${USUARIOS[0]}"
REMITENTE="${USUARIOS[1]}"
ANTES=$(doveadm mailbox status -u "$DESTINO" messages INBOX 2>/dev/null | grep -oE 'messages=[0-9]+' | cut -d= -f2)
ANTES=${ANTES:-0}

sendmail -f "${REMITENTE}@${DOMINIO}" "${DESTINO}@${DOMINIO}" <<EOF
From: ${REMITENTE}@${DOMINIO}
To: ${DESTINO}@${DOMINIO}
Subject: Prueba de instalacion RASBI Giron

Si estas leyendo esto desde Thunderbird, el correo funciona de punta a punta:
Postfix acepto el mensaje y Dovecot lo escribio e indexo por LMTP.
EOF

OK=0
for i in {1..15}; do
    sleep 2
    AHORA=$(doveadm mailbox status -u "$DESTINO" messages INBOX 2>/dev/null | grep -oE 'messages=[0-9]+' | cut -d= -f2)
    AHORA=${AHORA:-0}
    if (( AHORA > ANTES )); then OK=1; break; fi
done

if (( OK )); then
    echo -e "${VERDE}Correo entregado e indexado. INBOX de ${DESTINO}: ${AHORA} mensaje(s).${NC}"
    echo "Thunderbird va a ver esto mismo."
else
    aviso "El correo NO aparecio en INBOX. Diagnostico:"
    echo "--- mail.log ---";       tail -25 /var/log/mail.log 2>/dev/null || true
    echo "--- cola ---";           mailq || true
    echo "--- en disco ---";       ls -l "/home/${DESTINO}/Maildir/new/" "/home/${DESTINO}/Maildir/cur/" 2>/dev/null || true
    echo "--- rutas dovecot ---";  doveconf -n | grep -E "mail_driver|mail_path|mail_inbox_path" || true
    echo "--- estado INBOX ---";   doveadm mailbox status -u "$DESTINO" messages INBOX || true
    error "La entrega fallo. No se aplica la IP fija para que puedas seguir investigando con internet."
fi

#=============================================================================
# 8 - Firewall
#=============================================================================
paso "8/9 Firewall"

ufw allow 22/tcp
ufw allow 25/tcp
ufw allow 110/tcp
ufw allow 143/tcp
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

systemctl restart postfix dovecot
sleep 3

#=============================================================================
# Resumen
#=============================================================================
paso "Comprobacion final"

ip -br addr
ss -tln | grep -E ':25|:110|:143' || aviso "No se ven los puertos escuchando"
for u in "${USUARIOS[@]}"; do
    echo "INBOX de ${u}: $(doveadm mailbox status -u "$u" messages INBOX 2>/dev/null)"
done

echo -e "\n${VERDE}Listo. srv-mail en ${IPV4} / ${IPV6}${NC}"
cat <<EOF

 ===== CONFIGURACION EXACTA PARA THUNDERBIRD =====

 Al crear la cuenta, pulsa "Configurar manualmente". NO uses la deteccion
 automatica: busca puertos cifrados que este servidor no tiene.

 ENTRADA
   Protocolo .............. IMAP
   Servidor ............... email.${DOMINIO}
   Puerto ................. 143
   Seguridad .............. Ninguna
   Identificacion ......... Contrasena, transmitida de manera insegura
   Nombre de usuario ...... ${USUARIOS[0]}          <-- SIN el @${DOMINIO}

 SALIDA
   Servidor ............... email.${DOMINIO}
   Puerto ................. 25                     <-- NO 143
   Seguridad .............. Ninguna
   Identificacion ......... Sin autenticacion
   Nombre de usuario ...... (vacio)

 Contrasena de las dos cuentas: ${PASS_USUARIOS}
 Segundo buzon para probar envios: ${USUARIOS[1]}

 Los tres errores que mas cuestan:
   1. Poner "${USUARIOS[0]}@${DOMINIO}" como usuario -> rechaza la contrasena
      siempre. Dovecot autentica contra los usuarios de Linux.
   2. Dejar el puerto 143 en el servidor de SALIDA -> responde Dovecot con un
      saludo IMAP y Thunderbird aborta con "Error del servidor (SMTP)".
   3. Dejar "Contrasena" en la identificacion de salida -> Postfix no ofrece
      ese mecanismo y el envio falla.

 En la bandeja de ${USUARIOS[0]} ya hay un correo de prueba esperando.
EOF
