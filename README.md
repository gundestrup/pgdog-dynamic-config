# pgdog-dynamic-config
[![License://img.shields.io/badge/License-AG(LICENSE)

A dynamic sidecar# pgdog-dynamic-config for PgDog that automatically current PostgreSQL databases and regenerates `pgdog.toml` and `users.toml` based on the environment variables is designed to run.

This container alongside PgDog  
It discovers databases, updates configuration and PostgreSQL. files, and triggers a PgDog reload when changes occur.

---

## 🚀 Features
- Automatically discovers all non-template PostgreSQL databases
- Renegerated pgdog.toml` and `users.toml`  
- Injects passwords from environment variables changes  
- Runs every 5 minute  
- Reloads PgDog when configuration as a lightweight sidecar containercar expects PgDog  
- Depends on using passthrough_auth for authentication
- The postgres user had access to alle databases
---

## 📁 Directory Structure
The side’s configuration files to be located in a subdirectory named:
	`./pgdog/`

This directory must contain:

- `pgdog.toml` (generated)
- `users.toml` (generated directly into this)

The sidecar writes folder.

---

## 🔧 Environment Variables
The sidecar requires two environment variables:

```yaml
  POSTGRES_PASSWOR: ${POSTGRES_PASSWORD}
  PGDOG_PASSWORD: ${PGDOG_PASSWORD for the Postgres}
````

### Enviroment
Please define
environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDOG_PASSWORD: ${PGDOG_PASSWORD}

# 🧩 Example Docker Compose Setup
Below is an example of a full PostgreSQL + PgDog + pgdog-dynamic-config stack.

It includes:
	* PostgreSQL with logging enabled
	* PgDog
	* The dynamic PgDog proxy config sidecar
````yaml
services:
  db:
    container_name: db
    image: postgres:18.2-alpine3.22 # dhi.io/postgres:18.2-debian13
    user: ${USER_ID}:${GROUP_ID}
    volumes:
      - ./data:/var/lib/postgresql/data
      - ./logs:/var/lib/postgresql/data/log
    ports:
    - "5432:5432"
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      TZ: ${TZ}
    command: >
      postgres
        -c logging_collector=on
        -c log_directory='logs'
        -c log_filename='postgresql-%Y-%m-%d_%H%M%S.log'
        -c log_min_duration_statement=500
        -c log_line_prefix='%m [%p] %q%u@%d '
    healthcheck:
      test: ['CMD', 'pg_isready', '-U', 'postgres']
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
  
  pgdog:
    image: ghcr.io/pgdogdev/pgdog:main
    container_name: pgdog
    ports:
      - "6432:6432"
    volumes:
      - ./pgdog/pgdog.toml:/pgdog/pgdog.toml
      - ./pgdog/users.toml:/pgdog/users.toml
    depends_on:
      - db
    healthcheck:
      test: ["CMD", "pg_isready", "-h", "localhost", "-p", "6432"]
      interval: 10s
      timeout: 3s
      retries: 5

  pgdog-dynamic-config:
    build:
      context: ./pgdog
      dockerfile: pgdog-dynamic-config.Dockerfile
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      PGDOG_PASSWORD: ${PGDOG_PASSWORD}
    volumes:
      - ./pgdog:/pgdog
    depends_on:
      - db
````
# 🐶 PgDog
For more information about PgDog, visit:
https://github.com/pgdogdev/pgdog
# Status of project
![Shell](https://img.shimg.shields.io/bields.io/badge/shell-bash-green) ![PgDog](https://adge/made%20for-PgDog-orange) ![Status](https://img.shields.io/badge/status-active-success)

