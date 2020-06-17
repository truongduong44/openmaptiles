# Ensure that errors don't hide inside pipes
SHELL         = /bin/bash
.SHELLFLAGS   = -o pipefail -c

# Options to run with docker and docker-compose - ensure the container is destroyed on exit
# Containers run as the current user rather than root (so that created files are not root-owned)
DC_OPTS?=--rm -u $(shell id -u):$(shell id -g)

# If set to a non-empty value, will use postgis-preloaded instead of postgis docker image
USE_PRELOADED_IMAGE?=

# If set, this file will be imported in the import-osm target
PBF_FILE?=

# Allow a custom docker-compose project name
ifeq ($(strip $(DC_PROJECT)),)
  override DC_PROJECT:=$(notdir $(shell pwd))
  DOCKER_COMPOSE:= docker-compose
else
  DOCKER_COMPOSE:= docker-compose --project-name $(DC_PROJECT)
endif

# Make some operations quieter (e.g. inside the test script)
ifeq ($(strip $(QUIET)),)
  QUIET_FLAG:=
else
  QUIET_FLAG:=--quiet
endif

# Use `xargs --no-run-if-empty` flag, if supported
XARGS:=xargs $(shell xargs --no-run-if-empty </dev/null 2>/dev/null && echo --no-run-if-empty)

# If running in the test mode, compare files rather than copy them
TEST_MODE?=no
ifeq ($(TEST_MODE),yes)
  # create images in ./build/devdoc and compare them to ./layers
  GRAPH_PARAMS=./build/devdoc ./layers
else
  # update graphs in the ./layers dir
  GRAPH_PARAMS=./layers
endif

.PHONY: all
all: build/openmaptiles.tm2source/data.yml build/mapping.yaml build-sql

# Set OpenMapTiles host
OMT_HOST:=http://$(firstword $(subst :, ,$(subst tcp://,,$(DOCKER_HOST))) localhost)

.PHONY: help
help:
	@echo "=============================================================================="
	@echo " OpenMapTiles  https://github.com/openmaptiles/openmaptiles "
	@echo "Hints for testing areas                "
	@echo "  make list-geofabrik                  # list actual geofabrik OSM extracts for download -> <<your-area>> "
	@echo "  ./quickstart.sh <<your-area>>        # example:  ./quickstart.sh madagascar "
	@echo " "
	@echo "Hints for designers:"
	@echo "  make start-maputnik                  # start Maputnik Editor + dynamic tile server [ see $(OMT_HOST):8088 ]"
	@echo "  make start-postserve                 # start dynamic tile server                   [ see $(OMT_HOST):8090 ]"
	@echo "  make start-tileserver                # start maptiler/tileserver-gl                [ see $(OMT_HOST):8080 ]"
	@echo " "
	@echo "Hints for developers:"
	@echo "  make                                 # build source code"
	@echo "  make list-geofabrik                  # list actual geofabrik OSM extracts for download"
	@echo "  make download-geofabrik area=albania # download OSM data from geofabrik,        and create config file"
	@echo "  make download-osmfr area=asia/qatar  # download OSM data from openstreetmap.fr, and create config file"
	@echo "  make download-bbike area=Amsterdam   # download OSM data from bbike.org,        and create config file"
	@echo "  make psql                            # start PostgreSQL console"
	@echo "  make psql-list-tables                # list all PostgreSQL tables"
	@echo "  make vacuum-db                       # PostgreSQL: VACUUM ANALYZE"
	@echo "  make analyze-db                      # PostgreSQL: ANALYZE"
	@echo "  make generate-qareports              # generate reports                                [./build/qareports]"
	@echo "  make generate-devdoc                 # generate devdoc including graphs for all layers [./layers/...]"
	@echo "  make bash                            # start openmaptiles-tools /bin/bash terminal"
	@echo "  make destroy-db                      # remove docker containers and PostgreSQL data volume"
	@echo "  make start-db                        # start PostgreSQL, creating it if it doesn't exist"
	@echo "  make start-db-preloaded              # start PostgreSQL, creating data-prepopulated one if it doesn't exist"
	@echo "  make stop-db                         # stop PostgreSQL database without destroying the data"
	@echo "  make clean-unnecessary-docker        # clean unnecessary docker image(s) and container(s)"
	@echo "  make refresh-docker-images           # refresh openmaptiles docker images from Docker HUB"
	@echo "  make remove-docker-images            # remove openmaptiles docker images"
	@echo "  make pgclimb-list-views              # list PostgreSQL public schema views"
	@echo "  make pgclimb-list-tables             # list PostgreSQL public schema tables"
	@echo "  cat  .env                            # list PG database and MIN_ZOOM and MAX_ZOOM information"
	@echo "  cat  quickstart.log                  # transcript of the last ./quickstart.sh run"
	@echo "  make help                            # help about available commands"
	@echo "=============================================================================="

.PHONY: init-dirs
init-dirs:
	@mkdir -p build
	@mkdir -p data
	@mkdir -p cache

build/openmaptiles.tm2source/data.yml: init-dirs
	mkdir -p build/openmaptiles.tm2source
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools generate-tm2source openmaptiles.yaml --host="postgres" --port=5432 --database="openmaptiles" --user="openmaptiles" --password="openmaptiles" > $@

build/mapping.yaml: init-dirs
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools generate-imposm3 openmaptiles.yaml > $@

.PHONY: build-sql
build-sql: init-dirs
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools generate-sql openmaptiles.yaml > build/tileset.sql

.PHONY: clean
clean:
	rm -rf build

.PHONY: destroy-db
destroy-db: override DC_PROJECT:=$(shell echo $(DC_PROJECT) | tr A-Z a-z)
destroy-db:
	$(DOCKER_COMPOSE) down -v --remove-orphans
	$(DOCKER_COMPOSE) rm -fv
	docker volume ls -q -f "name=^$(DC_PROJECT)_" | $(XARGS) docker volume rm
	rm -rf cache

.PHONY: start-db-nowait
start-db-nowait:
	@echo "Starting postgres docker compose target using $${POSTGIS_IMAGE:-default} image (no recreate if exists)" && \
	$(DOCKER_COMPOSE) up --no-recreate -d postgres

.PHONY: start-db
start-db: start-db-nowait
	@echo "Wait for PostgreSQL to start..."
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools pgwait

# Wrap start-db target but use the preloaded image
.PHONY: start-db-preloaded
start-db-preloaded: export POSTGIS_IMAGE=openmaptiles/postgis-preloaded
start-db-preloaded: start-db

.PHONY: stop-db
stop-db:
	@echo "Stopping PostgreSQL..."
	$(DOCKER_COMPOSE) stop postgres

.PHONY: list-geofabrik
list-geofabrik:
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools download-osm list geofabrik

OSM_SERVERS:=geofabrik osmfr bbbike
ALL_DOWNLOADS:=$(addprefix download-,$(OSM_SERVERS))
OSM_SERVER=$(patsubst download-%,%,$@)
.PHONY: $(ALL_DOWNLOADS)
$(ALL_DOWNLOADS): init-dirs
ifeq ($(strip $(area)),)
	@echo ""
	@echo "ERROR: Unable to download an area if area is not given."
	@echo "Usage:"
	@echo "  make download-$(OSM_SERVER) area=<area-id>"
	@echo ""
	$(if $(filter %-geofabrik,$@),@echo "Use   make list-geofabrik   to get a list of all available areas";echo "")
	@exit 1
else
	@echo "=============== download-$(OSM_SERVER) ======================="
	@echo "Download area: $(area)"
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools bash -c \
		'download-osm $(OSM_SERVER) $(area) \
			--minzoom $$QUICKSTART_MIN_ZOOM \
			--maxzoom $$QUICKSTART_MAX_ZOOM \
			--make-dc /import/docker-compose-config.yml -- -d /import'
	ls -la ./data/$(notdir $(area))*
	@echo ""
endif

.PHONY: psql
psql: start-db-nowait
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools sh -c 'pgwait && psql.sh'

.PHONY: import-osm
import-osm: all start-db-nowait
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools sh -c 'pgwait && import-osm $(PBF_FILE)'

.PHONY: update-osm
update-osm: all start-db-nowait
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools sh -c 'pgwait && import-update'

.PHONY: import-diff
import-diff: all start-db-nowait
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools sh -c 'pgwait && import-diff'

.PHONY: import-data
import-data: start-db
	$(DOCKER_COMPOSE) run $(DC_OPTS) import-data

.PHONY: import-borders
import-borders: start-db-nowait
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools sh -c 'pgwait && import-borders'

.PHONY: import-sql
import-sql: all start-db-nowait
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools sh -c 'pgwait && import-sql' | \
	  awk -v s=": WARNING:" '$$0~s{print; print "\n*** WARNING detected, aborting"; exit(1)} 1'

.PHONY: generate-tiles
ifneq ($(wildcard data/docker-compose-config.yml),)
  DC_CONFIG_TILES:=-f docker-compose.yml -f ./data/docker-compose-config.yml
endif
generate-tiles: init-dirs all start-db
	rm -rf data/tiles.mbtiles
	echo "Generating tiles ..."; \
	$(DOCKER_COMPOSE) $(DC_CONFIG_TILES) run $(DC_OPTS) generate-vectortiles
	@echo "Updating generated tile metadata ..."
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools generate-metadata ./data/tiles.mbtiles

.PHONY: start-tileserver
start-tileserver: init-dirs
	@echo " "
	@echo "***********************************************************"
	@echo "* "
	@echo "* Download/refresh maptiler/tileserver-gl docker image"
	@echo "* see documentation: https://github.com/maptiler/tileserver-gl"
	@echo "* "
	@echo "***********************************************************"
	@echo " "
	docker pull maptiler/tileserver-gl
	@echo " "
	@echo "***********************************************************"
	@echo "* "
	@echo "* Start maptiler/tileserver-gl "
	@echo "*       ----------------------------> check $(OMT_HOST):8080 "
	@echo "* "
	@echo "***********************************************************"
	@echo " "
	docker run $(DC_OPTS) -it --name tileserver-gl -v $$(pwd)/data:/data -p 8080:8080 maptiler/tileserver-gl --port 8080

.PHONY: start-postserve
start-postserve: start-db
	@echo " "
	@echo "***********************************************************"
	@echo "* "
	@echo "* Bring up postserve at $(OMT_HOST):8090"
	@echo "*     --> can view it locally (use make start-maputnik)"
	@echo "*     --> or can use https://maputnik.github.io/editor"
	@echo "* "
	@echo "*  set data source / TileJSON URL to http://$(OMT_HOST):8090"
	@echo "* "
	@echo "***********************************************************"
	@echo " "
	$(DOCKER_COMPOSE) up -d postserve

.PHONY: stop-postserve
stop-postserve:
	$(DOCKER_COMPOSE) stop postserve

.PHONY: start-maputnik
start-maputnik: stop-maputnik start-postserve
	@echo " "
	@echo "***********************************************************"
	@echo "* "
	@echo "* Start maputnik/editor "
	@echo "*       ---> go to http://$(OMT_HOST):8088 "
	@echo "*       ---> set data source / TileJSON URL to http://$(OMT_HOST):8090"
	@echo "* "
	@echo "***********************************************************"
	@echo " "
	docker run $(DC_OPTS) --name maputnik_editor -d -p 8088:8888 maputnik/editor

.PHONY: stop-maputnik
stop-maputnik:
	-docker rm -f maputnik_editor

.PHONY: generate-qareports
generate-qareports: start-db
	./qa/run.sh

# generate all etl and mapping graphs
.PHONY: generate-devdoc
generate-devdoc: init-dirs
	mkdir -p ./build/devdoc && \
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools sh -c \
			'generate-etlgraph openmaptiles.yaml $(GRAPH_PARAMS) && \
			 generate-mapping-graph openmaptiles.yaml $(GRAPH_PARAMS)'

.PHONY: bash
bash:
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools bash

.PHONY: import-wikidata
import-wikidata:
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools import-wikidata --cache /cache/wikidata-cache.json openmaptiles.yaml

.PHONY: reset-db-stats
reset-db-stats:
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools psql.sh -v ON_ERROR_STOP=1 -P pager=off -c 'SELECT pg_stat_statements_reset();'

.PHONY: list-views
list-views:
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools psql.sh -v ON_ERROR_STOP=1 -A -F"," -P pager=off -P footer=off \
		-c "select schemaname, viewname from pg_views where schemaname='public' order by viewname;"

.PHONY: list-tables
list-tables:
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools psql.sh -v ON_ERROR_STOP=1 -A -F"," -P pager=off -P footer=off \
		-c "select schemaname, tablename from pg_tables where schemaname='public' order by tablename;"

.PHONY: psql-list-tables
psql-list-tables:
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools psql.sh -v ON_ERROR_STOP=1 -P pager=off -c "\d+"

.PHONY: vacuum-db
vacuum-db:
	@echo "Start - postgresql: VACUUM ANALYZE VERBOSE;"
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools psql.sh -v ON_ERROR_STOP=1 -P pager=off -c 'VACUUM ANALYZE VERBOSE;'

.PHONY: analyze-db
analyze-db:
	@echo "Start - postgresql: ANALYZE VERBOSE;"
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools psql.sh -v ON_ERROR_STOP=1 -P pager=off -c 'ANALYZE VERBOSE;'

.PHONY: list-docker-images
list-docker-images:
	docker images | grep openmaptiles

.PHONY: refresh-docker-images
refresh-docker-images:
ifneq ($(strip $(NO_REFRESH)),)
	@echo "Skipping docker image refresh"
else
	@echo ""
	@echo "Refreshing docker images... Use NO_REFRESH=1 to skip."
ifneq ($(strip $(USE_PRELOADED_IMAGE)),)
	POSTGIS_IMAGE=openmaptiles/postgis-preloaded \
		docker-compose pull --ignore-pull-failures $(QUIET_FLAG) openmaptiles-tools generate-vectortiles postgres
else
	docker-compose pull --ignore-pull-failures $(QUIET_FLAG) openmaptiles-tools generate-vectortiles postgres import-data
endif
endif

.PHONY: remove-docker-images
remove-docker-images:
	@echo "Deleting all openmaptiles related docker image(s)..."
	@$(DOCKER_COMPOSE) down
	@docker images "openmaptiles/*" -q                | $(XARGS) docker rmi -f
	@docker images "maputnik/editor" -q               | $(XARGS) docker rmi -f
	@docker images "maptiler/tileserver-gl" -q        | $(XARGS) docker rmi -f

.PHONY: clean-unnecessary-docker
clean-unnecessary-docker:
	@echo "Deleting unnecessary container(s)..."
	@docker ps -a --filter "status=exited" | $(XARGS) docker rm
	@echo "Deleting unnecessary image(s)..."
	@docker images | grep \<none\> | awk -F" " '{print $$3}' | $(XARGS) docker rmi

.PHONY: test-perf-null
test-perf-null:
	$(DOCKER_COMPOSE) run $(DC_OPTS) openmaptiles-tools test-perf openmaptiles.yaml --test null --no-color

.PHONY: build-test-pbf
build-test-pbf:
	docker-compose run $(DC_OPTS) openmaptiles-tools /tileset/.github/workflows/build-test-data.sh
