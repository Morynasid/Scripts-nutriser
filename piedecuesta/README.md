# Sede Piedecuesta - fortkorp.com

Servidor web (Apache HTTPS + vsftpd FTPS) de la sede Piedecuesta.

## Instalar

En la VM de Ubuntu Server, **con la red todavia en DHCP** (el script aplica la
IP fija al final):

```bash
sudo apt update && sudo apt -y install git
git clone https://github.com/Morynasid/Scripts-nutriser.git
cd Scripts-nutriser/piedecuesta
sudo bash srv-web-piedecuesta.sh
```

El script detecta solo la carpeta `PROYECTO-PI-desarrollo/` que esta a su lado.

## Direccionamiento

| Dato            | Valor                |
|-----------------|----------------------|
| IPv4            | 172.22.1.20/24       |
| IPv6            | 2801:F:1::20/64      |
| Gateway         | 172.22.1.1           |
| Gateway IPv6    | 2801:F:1::1          |
| DNS             | 172.22.1.4           |
| Raiz web        | /var/www/fortkorp    |
| Usuario FTPS    | respaldo / Pied2026  |

## Registros que hay que crear en el DNS de Piedecuesta (172.22.1.4)

Zona `fortkorp.com`:

```
web   IN  A     172.22.1.20
web   IN  AAAA  2801:F:1::20
ftp   IN  A     172.22.1.20
ftp   IN  AAAA  2801:F:1::20
www   IN  CNAME web.fortkorp.com.
```

Zona inversa `1.22.172.in-addr.arpa`:

```
20    IN  PTR   web.fortkorp.com.
```

Subir el serial del SOA y recargar: `sudo rndc reload`

## Nota sobre el diseno

La pagina carga Font Awesome desde cdnjs, la tipografia Poppins desde Google
Fonts y un mapa embebido de Google Maps. Sin salida a internet se vera con la
fuente por defecto, sin iconos y con el mapa en blanco. El contenido y el
maquetado funcionan igual.
