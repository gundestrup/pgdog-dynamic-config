root@truenas[/mnt/docker/Apps/postgres/pgdog]# cat generate-config.sh 
#!/bin/sh

set -e

TMP=/pgdog/pgdog.toml.tmp
OUT=/pgdog/pgdog.toml

export PGPASSWORD="$POSTGRES_PASSWORD"
export PGDOGPASSWORD="$PGDOG_PASSWORD"

echo "DEBUG: POSTGRES_PASSWORD='$POSTGRES_PASSWORD'"
echo "DEBUG: PGPASSWORD='$PGPASSWORD'"
echo "DEBUG: PGDOG_PASSWORD='$PGDOG_PASSWORD'"
echo "DEBUG: PGDOGPASSWORD='$PGDOGPASSWORD'"

# Hent alle ikke-template databaser
DBS=$(psql -h db -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;")

# Generér config
echo '[general]' > $TMP
echo 'port = 6432' >> $TMP
echo 'default_pool_size = 10' >> $TMP
echo 'passthrough_auth = "enabled_plain"' >> $TMP
echo 'openmetrics_port = 9090' >> $TMP
echo 'openmetrics_namespace = "pgdog_"' >> $TMP

for DB in $DBS; do
  echo '' >> $TMP
  echo '[[databases]]' >> $TMP
  echo "name = \"$DB\"" >> $TMP
  echo 'host = "db"' >> $TMP
  echo 'port = 5432' >> $TMP
done

# --- GENERATE users.toml ---

USERS_TMP=/pgdog/users.toml.tmp
USERS_OUT=/pgdog/users.toml

# 1. Skriv statisk pgdog-bruger
echo '[[users]]' > $USERS_TMP
echo 'name="pgdog"' >> $USERS_TMP
echo "password=\"$PGDOGPASSWORD\"" >> "$USERS_TMP"
echo 'database="pgdog"' >> $USERS_TMP

echo '' >> $USERS_TMP

# 2. Dynamisk postgres-bruger
echo '[[users]]' >> $USERS_TMP
echo 'name="postgres"' >> $USERS_TMP
echo "password=\"$PGPASSWORD\"" >> "$USERS_TMP"
echo -n 'databases=[' >> $USERS_TMP

echo ']' >> $USERS_TMP

# --- RELOAD pgdog.toml og users.toml hvis ændret ---
if ! cmp -s $TMP $OUT; then
  echo "Config changed — updating PgDog config"
  mv $TMP $OUT
  mv $USERS_TMP $USERS_OUT
  pkill -HUP pgdog || true
else
  echo "No changes"
fi