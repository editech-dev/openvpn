# Atajos de operación. `make help` lista los comandos.
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
COMPOSE ?= docker compose

.PHONY: help init up down restart apply ps logs users status config export export-zip backup build pull lint test test-unit test-smoke

help: ## Muestra esta ayuda
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z_-]+:.*## /{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

init: ## Crea .env a partir de .env.example (no sobrescribe)
	@test -f .env && echo ".env ya existe" || (cp .env.example .env && chmod 600 .env && echo "Creado .env: edítalo antes de 'make up'")

up: ## Levanta los servicios
	$(COMPOSE) up -d --remove-orphans

down: ## Detiene los servicios (conserva la PKI)
	$(COMPOSE) down

restart: ## Reinicia OpenVPN
	$(COMPOSE) restart openvpn

apply: ## Aplica cambios del .env (altas/bajas de OVPN_USERS)
	./scripts/ovpn.sh apply

ps: ## Estado de los contenedores
	$(COMPOSE) ps

logs: ## Sigue los logs
	$(COMPOSE) logs -f --tail 100

users: ## Lista usuarios y estado de sus certificados
	./scripts/ovpn.sh users list

status: ## Clientes conectados
	./scripts/ovpn.sh status

config: ## Muestra el server.conf generado
	./scripts/ovpn.sh config

export: ## Exporta los .ovpn de todos los usuarios activos a ./exports
	./scripts/export-clients.sh

export-zip: ## Igual que export y además genera un .zip
	./scripts/export-clients.sh --zip

backup: ## Backup del volumen PKI en ./backups
	./scripts/backup-pki.sh backup

build: ## Construye la imagen localmente
	$(COMPOSE) build openvpn

pull: ## Descarga las imágenes publicadas
	$(COMPOSE) pull

lint: ## shellcheck + hadolint + validación de compose
	docker run --rm -v "$(CURDIR):/mnt:ro" -w /mnt koalaman/shellcheck:stable -x openvpn/entrypoint.sh openvpn/ovpnctl openvpn/healthcheck.sh openvpn/lib/*.sh scripts/*.sh tests/smoke.sh
	docker run --rm -i hadolint/hadolint < openvpn/Dockerfile
	$(COMPOSE) --env-file .env.example config -q

test: test-unit test-smoke ## Todas las pruebas

test-unit: ## Pruebas unitarias (bats)
	docker run --rm -v "$(CURDIR):/code:ro" -w /code bats/bats:latest -r tests/unit

test-smoke: ## Prueba end-to-end con un cliente real
	./tests/smoke.sh
