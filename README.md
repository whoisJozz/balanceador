# Balanceador de carga con Docker (HTTP + MySQL) en Ubuntu Server

Proyecto base: HAProxy balanceando tráfico HTTP entre dos servidores Nginx,
y tráfico MySQL entre un nodo primario y una réplica (en modo backup/failover).

```
lb-project/
├── docker-compose.yml
├── haproxy/
│   └── haproxy.cfg
├── web1/html/index.html
├── web2/html/index.html
└── README.md
```

## 1. Requisitos previos en Ubuntu Server

Instala Docker Engine y el plugin de Compose:

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Para usar docker sin sudo (opcional, requiere volver a iniciar sesión)
sudo usermod -aG docker $USER
```

Verifica: `docker --version` y `docker compose version`.

## 2. Levantar el stack

Copia esta carpeta a tu servidor (por ejemplo con `scp` o `git clone` si la subes a un repo) y desde dentro de `lb-project/`:

```bash
docker compose up -d
docker compose ps
```

Deberías ver 5 contenedores corriendo: `lb_haproxy`, `web1`, `web2`, `mysql_primary`, `mysql_replica`.

## 3. Crear el usuario de health-check en MySQL

HAProxy usa `option mysql-check` para saber si cada nodo MySQL está vivo. Ese chequeo necesita un usuario sin contraseña con permiso mínimo. Créalo en **ambos** nodos:

```bash
docker exec -it mysql_primary mysql -uroot -prootpass -e \
  "CREATE USER 'haproxy_check'@'%'; FLUSH PRIVILEGES;"

docker exec -it mysql_replica mysql -uroot -prootpass -e \
  "CREATE USER 'haproxy_check'@'%'; FLUSH PRIVILEGES;"
```

## 4. Probar el balanceo HTTP

```bash
for i in {1..6}; do curl -s http://localhost | grep Respondiendo; done
```

Deberías ver alternar "WEB 1" y "WEB 2".

## 5. Probar la conexión MySQL a través del balanceador

```bash
mysql -h 127.0.0.1 -P 3306 -uappuser -papppass appdb -e "SELECT 1;"
```

Esa conexión siempre caerá en `mysql_primary` mientras esté disponible (la réplica está marcada como `backup`, solo entra si el primario cae).

## 6. Ver el dashboard de HAProxy

Abre `http://<ip-del-servidor>:8404/` en el navegador para ver el estado de cada backend en tiempo real (verde = healthy, rojo = caído).

## 7. Red clase C con IPs fijas

Por defecto, Docker asigna a sus redes bridge un rango **clase B** (`172.17.0.0/16`, `172.18.0.0/16`, etc., dentro del bloque privado 172.16.0.0/12). En este proyecto la red `lb_network` está definida explícitamente con un subnet **clase C** (`192.168.100.0/24`, dentro del bloque privado 192.168.0.0/16) y cada contenedor tiene una IP fija asignada con `ipv4_address`:

| Contenedor       | IP fija         |
|------------------|------------------|
| lb_haproxy       | 192.168.100.10   |
| web1             | 192.168.100.11   |
| web2             | 192.168.100.12   |
| mysql_primary    | 192.168.100.13   |
| mysql_replica    | 192.168.100.14   |

Así, cuando HAProxy alterna entre `web1` y `web2` (round-robin), la página de respuesta muestra explícitamente la IP clase C del contenedor que atendió la petición, en vez de una IP clase B genérica asignada al vuelo.

Para verificarlo:

```bash
# Ver el subnet real de la red
docker network inspect lb-project_lb_network | grep -A2 IPAM

# Ver la IP asignada a cada contenedor
docker inspect web1 | grep IPAddress
docker inspect web2 | grep IPAddress

# Probar el balanceo y ver la IP cambiar en cada respuesta
for i in {1..6}; do curl -s http://localhost | grep -E "WEB|IP del"; echo "---"; done
```

> Nota: el nombre de la red en `docker network inspect` normalmente lleva el prefijo del nombre de la carpeta del proyecto (por ejemplo `lb-project_lb_network`). Usa `docker network ls` para confirmar el nombre exacto en tu servidor.

## 8. Replicación MySQL (primario → réplica con GTID)

`docker-compose.yml` ya trae los flags necesarios en `mysql-primary` y `mysql-replica`:
`--server-id`, `--log-bin`, `--gtid-mode=ON`, `--enforce-gtid-consistency=ON`. La réplica además arranca en `--read-only` / `--super-read-only` para que nadie escriba ahí por accidente.

**Paso 1 — Aplicar los nuevos flags a los contenedores.** Si ya los habías levantado antes con la config anterior, recréalos (esto no borra los datos, el volumen persiste):

```bash
docker compose up -d --force-recreate mysql-primary mysql-replica
```

**Paso 2 — Ejecutar el script de configuración:**

```bash
chmod +x scripts/setup-replication.sh
./scripts/setup-replication.sh
```

El script espera a que ambos MySQL respondan, crea el usuario `repl` en el primario y configura la réplica con `CHANGE REPLICATION SOURCE TO ... SOURCE_AUTO_POSITION=1` (usa GTID, así que no hay que calcular posiciones de binlog a mano). Al final imprime el estado — busca que `Replica_IO_Running` y `Replica_SQL_Running` digan `Yes`.

**Paso 3 — Probarlo con datos reales:**

```bash
# Escribe en el primario
docker exec -it mysql_primary mysql -uroot -prootpass appdb -e \
  "CREATE TABLE IF NOT EXISTS prueba (id INT PRIMARY KEY, msg VARCHAR(50));
   INSERT INTO prueba VALUES (1, 'hola desde primario');"

# Verifica que llegó a la réplica
docker exec -it mysql_replica mysql -uroot -prootpass appdb -e "SELECT * FROM prueba;"
```

Si ves la fila reflejada en la réplica, la replicación está funcionando.

> Si `mysql-replica` ya tenía un dataset previo con escrituras hechas *sin* GTID antes de este cambio, `SOURCE_AUTO_POSITION=1` puede fallar por inconsistencia de GTIDs. En un entorno nuevo de pruebas (como este) no debería pasar; si pasa, lo más simple es borrar el volumen de la réplica (`docker compose down` + `docker volume rm lb-project_mysql_replica_data`) y volver a levantarla desde cero.

## 9. Notas de seguridad para producción

- **No expongas el puerto 3306 a Internet.** Bloquéalo con `ufw` y permite solo la IP de tu servidor de aplicaciones:
  ```bash
  sudo ufw allow from <ip-app-server> to any port 3306
  sudo ufw deny 3306
  ```
- Cambia las contraseñas de ejemplo (`rootpass`, `apppass`) antes de usar esto en serio; usa `docker secrets` o un `.env` fuera del control de versiones.
- El dashboard de stats (`:8404`) no tiene autenticación en este ejemplo — agrégale `stats auth usuario:clave` en `haproxy.cfg` o restringe el puerto con `ufw`.
- Considera TLS/HTTPS en el frontend HTTP (HAProxy puede terminar TLS con `bind *:443 ssl crt ...`).

## 10. Si necesitas separar lecturas y escrituras de verdad

HAProxy en modo TCP no entiende SQL, así que no puede mandar `SELECT` a la réplica y `INSERT/UPDATE` al primario automáticamente. Para eso existe **ProxySQL**, un proxy consciente del protocolo MySQL que sí puede hacer ese split por tipo de query. Si tu app va a crecer en lecturas, vale la pena migrar esa pieza a ProxySQL más adelante; el balanceo HTTP con HAProxy se queda igual.
