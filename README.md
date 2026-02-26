# pg-docker-tools

Docker-based PostgreSQL dump/restore helpers.

## Requirements

- Docker
- `yq` (v4)
- PostgreSQL Docker images available for the versions in `config.yaml`

## Install

```bash
# Copy the folder or add it to your PATH.
```

## Check dependencies

```bash
./bin/check_deps.sh
```

## Configuration

Edit `config.yaml` and export a password per database + environment:

```bash
export PGPASSWORD_APP_LOCAL=example
export PGPASSWORD_APP_PROD=example
```

## Quickstart (local Docker)

```bash
docker compose -f docker-compose.yml up -d
export PGPASSWORD_APP_LOCAL=postgres
./bin/pg_dump.sh app local
./bin/pg_restore.sh app local backups/app/local/app_*.dump --no-clean
docker compose -f docker-compose.yml down -v
```

## Dump

```bash
./bin/pg_dump.sh app local
./bin/pg_dump.sh app prod --format directory --jobs 8
./bin/pg_dump.sh app prod --keep-days 7 --keep-count 5
./bin/pg_dump.sh app prod --mode host
```

Selective table data (requires `exclude_data` in `config.yaml`):

```bash
# Dump everything except the listed tables' data
./bin/pg_dump.sh app prod --with-excludes

# Dump data only for the excluded tables (useful for splitting large tables into a separate file)
./bin/pg_dump.sh app prod --only-excludes
```

## Restore

```bash
./bin/pg_restore.sh app local backups/app/local/app_20240101_120000.dump
./bin/pg_restore.sh app prod backups/app/prod/app_20240101_120000.dump --no-clean
./bin/pg_restore.sh app prod backups/app/prod/app_20240101_120000.dumpdir --jobs 8
./bin/pg_restore.sh app prod backups/app/prod/app_20240101_120000.dump --mode host
```

Restore a subset of objects using a TOC list file:

```bash
# Generate a TOC list from a dump
pg_restore -l backups/app/prod/app_20240101_120000.dump > toc.list
# Edit toc.list to comment out unwanted entries, then restore selectively
./bin/pg_restore.sh app prod backups/app/prod/app_20240101_120000.dump --toc toc.list
```

## Development

```bash
bash -n bin/*.sh
```

## Optional integration test

```bash
./tests/run_integration.sh
```

## Docker image

```bash
docker build -t pg-docker-tools . \
  --build-arg PG_CLIENT_VERSION=16 \
  --build-arg YQ_VERSION=v4.44.1
```

## Publish image (GHCR)

Tag a release to publish:

```bash
git tag pg-docker-tools-v0.1.0
git push origin pg-docker-tools-v0.1.0
```

Images are pushed to:

```
ghcr.io/larsderidder/pg-docker-tools:0.1.0
ghcr.io/larsderidder/pg-docker-tools:latest
```
