#!/bin/bash
set -e

# The script will be run by the MySQL container on the initial startup.
# Make sure that the environment variables mentioned below are set in docker-compose.yml:
# MYSQL_ROOT_PASSWORD, MYSQL_NEXTCLOUD_PASSWORD, MYSQL_PHOTOPRISM_PASSWORD, etc.

mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
    CREATE DATABASE IF NOT EXISTS ${MYSQL_NEXTCLOUD_DATABASE};
    CREATE USER IF NOT EXISTS '${MYSQL_NEXTCLOUD_USER}'@'%' IDENTIFIED BY '${MYSQL_NEXTCLOUD_PASSWORD}';
    GRANT ALL PRIVILEGES ON ${MYSQL_NEXTCLOUD_DATABASE}.* TO '${MYSQL_NEXTCLOUD_USER}'@'%';
    FLUSH PRIVILEGES;
EOSQL
