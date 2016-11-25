SHELL = /bin/bash

PROJECT_NAME ?= todobackend
ORG_NAME ?= magln
REPO_NAME ?= todobackend

DEV_COMPOSE_FILE := docker/dev/docker-compose.yml
REL_COMPOSITE_FILE := docker/release/docker-compose.yml

REL_PROJECT := $(PROJECT_NAME)$(BUILD_ID)
DEV_PROJECT := $(REL_PROJECT)dev

APP_SERVICE_NAME := app

RELEASE_ARGS := -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE)

get_container_id = $$(docker-compose $(1) ps -q $(2))
get_service_health = $$(echo $(call get_container_id,$(1),$(2)) | xargs -I ID docker inspect -f '{{ .State.Health.Status }}' ID)
check_service_health = { \
	until [[ $(call get_service_health,$(1),$(2)) != starting ]]; \
		do sleep 1; \
	done; \
	if [[ $(call get_service_health,$(1),$(2)) != healthy ]]; \
		then echo $(2) failed health check; exit 1; \
	fi; \
}

get_exit_status = $$(docker-compose -p $(1) -f $(2) ps -q $(3) | xargs -I ARGS docker inspect -f "{{ .State.ExitCode }}" ARGS)
check_exit_status = { \
	if [[ $(call get_exit_status,$(1),$(2),$(3)) != 0 ]]; \
		then exit $(call get_exit_status,$(1),$(2),$(3)); \
	fi; \
}

DOCKER_REGISTRY ?= docker.io

.PHONY: test build release clean tag

test:
	${INFO} "Pulling latest images..."
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) pull
	${INFO} "Building images..."
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) build --pull test
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) build cache
	${INFO} "Ensuring database is ready..."
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) run --rm agent
	${INFO} "Running tests..."
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) up test
	@ docker cp $$(docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) ps -q test):/reports/. reports
	@ $(call check_exit_status,$(DEV_PROJECT),$(DEV_COMPOSE_FILE),test)
	${INFO} "Testing complete"

build:
	${INFO} "Creating builder image..."
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) build builder
	${INFO} "Building application artifacts..."
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) up builder
	@ $(call check_exit_status,$(DEV_PROJECT),$(DEV_COMPOSE_FILE),builder)
	${INFO} "Copying artifacts to target folder..."
	@ docker cp $$(docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) ps -q builder):/wheelhouse/. target
	${INFO} "Build complete"

release:
	${INFO} "Pulling latest images..."
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) pull test
	${INFO} "Building images..."
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) build app
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) build webroot
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) build --pull nginx
	${INFO} "Ensuring database is ready..."
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) run --rm agent
	${INFO} "Collecting static files..."
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) run --rm app manage.py collectstatic --noinput
	${INFO} "Running database migrations..."
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) run --rm app manage.py migrate --noinput
	${INFO} "Starting nginx"
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) up -d nginx
	${INFO} "Ensuring server is ready..."
	@ $(call check_service_health,$(RELEASE_ARGS),nginx)
	${INFO} "Running acceptance tests..."
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) up test
	@ docker cp $$(docker-compose -p $(DEV_PROJECT) -f $(REL_COMPOSITE_FILE) ps -q test):/reports/. reports
	@ $(call check_exit_status,$(REL_PROJECT),$(REL_COMPOSITE_FILE),test)
	${INFO} "Acceptance testing complete"

clean:
	${INFO} "Destorying development environment..."
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) kill
	@ docker-compose -p $(DEV_PROJECT) -f $(DEV_COMPOSE_FILE) rm -f	-v
	${INFO} "Destroying release environment..."
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) kill
	@ docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSITE_FILE) rm -f	-v
	${INFO} "Removing dangling images..."
	@ docker images -q -f dangling=true -f label=application=$(REPO_NAME) | xargs -I ARGS docker rmi -f ARGS
	${INFO} "Clean complete"

tag:
	@{INFO} "Tagging release image with tags $(TAG_ARGS)..."
	@ $(foreach tag, $(TAG_ARGS), docker tag $(IMAGE_ID) $(DOCKER_REGISTRY)/$(ORG_NAME)/$(REPO_NAME):$(tag);)
	${INFO} "Tagging complete"
	
YELLOW := "\e[1;33m"
NC := "\e[0m"

INFO := @bash -c '\
	printf $(YELLOW); \
	echo "=> $$1"; \
	printf $(NC)' VALUE

APP_CONTAINER_ID := $$(docker-compose -p $(REL_PROJECT) -f $(REL_COMPOSE_FILE) ps -q $(APP_SERVICE_NAME))

IMAGE_ID := $$(docker inspect -f '{{ .Image }}' $(APP_CONTAINER_ID))

ifeq (tag, $(firstword $(MAKECMDGOALS)))
	TAG_ARGS := $(Wordlist 2, $(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
	ifeq ($(TAG_ARGS),)
		$(error You must specify a tag)
	endif
	$(eval $(TAG_ARGS):;$:)
endif