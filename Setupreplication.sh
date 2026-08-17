#!/usr/bin/env bash
# Configura replicación GTID entre mysql_primary y mysql_replica.
# Requiere que ambos contenedores ya estén levantados con los flags
# --server-id / --log-bin / --gtid-mode definidos en docker-compose.yml.
set -euo pipefail

ROOT_PASS="rootpass"
REPL_USER="repl"
REPL_PASS="replpass"
PRIMARY_CONTAINER="mysql_primary"
REPLICA_CONTAINER="mysql_replica"

wait_for_mysql() {
  local container="$1"
  echo "Esperando a que $container acepte conexiones..."
  until docker exec "$container" mysqladmin ping -uroot -p"$ROOT_PASS" --silent 2>/dev/null; do
    sleep 2
  done
  echo "$container listo."
}

wait_for_mysql "$PRIMARY_CONTAINER"
wait_for_mysql "$REPLICA_CONTAINER"

echo "Creando usuario de replicación en el primario..."
docker exec -i "$PRIMARY_CONTAINER" mysql -uroot -p"$ROOT_PASS" <<SQL
CREATE USER IF NOT EXISTS '${REPL_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${REPL_PASS}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "Apuntando la réplica hacia el primario (GTID auto-position)..."
docker exec -i "$REPLICA_CONTAINER" mysql -uroot -p"$ROOT_PASS" -f <<SQL
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-primary',
  SOURCE_PORT=3306,
  SOURCE_USER='${REPL_USER}',
  SOURCE_PASSWORD='${REPL_PASS}',
  SOURCE_AUTO_POSITION=1;
START REPLICA;
SQL

echo ""
echo "Estado de la réplica:"
docker exec "$REPLICA_CONTAINER" mysql -uroot -p"$ROOT_PASS" -e "SHOW REPLICA STATUS\G" \
  | grep -E "Replica_IO_Running|Replica_SQL_Running|Last_IO_Error|Last_SQL_Error"

echo ""
echo "Si Replica_IO_Running y Replica_SQL_Running dicen 'Yes', la replicación quedó activa."