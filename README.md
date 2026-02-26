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

## Backup and restore procedures

### Setting up for a new project

1. Copy `config.yaml` into your project and define your databases and environments:

```yaml
databases:
  myapp:
    local:
      pg_version: "16"
      host: localhost
      db: myapp
      user: myapp
      network: ""        # empty = use host networking
    prod:
      pg_version: "16"
      host: db.example.com
      db: myapp
      user: myapp
      exclude_data:
        - audit_log      # tables whose data to skip in normal dumps
```

2. Export a password for each database/environment combination. The variable name is
   `PGPASSWORD_<DB_ID>_<ENV>` in uppercase:

```bash
export PGPASSWORD_MYAPP_LOCAL=secret
export PGPASSWORD_MYAPP_PROD=secret
```

Put these in your shell profile, a `.env` file sourced in your workflow, or CI secrets.
Never commit them.

3. Check that dependencies are available:

```bash
./bin/check_deps.sh
```

### Regular backups

Run a dump at any time:

```bash
./bin/pg_dump.sh myapp prod
```

The dump lands in `backups/myapp/prod/myapp_<timestamp>.dump` and a `.sha256` checksum file
is written alongside it.

To verify the checksum later:

```bash
sha256sum -c backups/myapp/prod/myapp_20260101_020000.dump.sha256
```

To keep storage bounded, use retention flags:

```bash
# Keep only the last 7 days and at most 10 files
./bin/pg_dump.sh myapp prod --keep-days 7 --keep-count 10
```

For large databases, use the directory format with parallel workers:

```bash
./bin/pg_dump.sh myapp prod --format directory --jobs 8
```

### Automated backups (cron or Kubernetes)

For a simple cron job on a server:

```bash
# /etc/cron.d/pgtools-backup
0 2 * * * deploy PGPASSWORD_MYAPP_PROD=secret /opt/pgtools/bin/pg_dump.sh myapp prod \
  --keep-days 14 --keep-count 20 >> /var/log/pgtools.log 2>&1
```

For Kubernetes, see the reference manifests in `k8s/`. Apply them in order:

```bash
kubectl apply -f k8s/pvc.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml        # edit the password placeholder first
kubectl apply -f k8s/cronjob-backup.yaml
```

Run a one-off backup job:

```bash
kubectl apply -f k8s/job-backup.yaml
kubectl logs -f job/pgtools-backup-job
```

### Restoring from a backup

**Standard restore** (drops and recreates objects before restoring):

```bash
./bin/pg_restore.sh myapp prod backups/myapp/prod/myapp_20260101_020000.dump
```

**Restoring to a different or fresh database** (no pre-drop):

```bash
./bin/pg_restore.sh myapp prod backups/myapp/prod/myapp_20260101_020000.dump --no-clean
```

Restoring to production requires typing `RESTORE PROD` as a confirmation prompt.

**Parallel restore** (directory format dumps only):

```bash
./bin/pg_restore.sh myapp prod backups/myapp/prod/myapp_20260101_020000.dumpdir --jobs 8
```

### Partial restore using a TOC list

To restore only specific tables or objects:

```bash
# 1. Generate the TOC list from the dump
pg_restore -l backups/myapp/prod/myapp_20260101_020000.dump > toc.list

# 2. Comment out lines for objects you do not want to restore
#    Lines starting with ";" are ignored by pg_restore
vi toc.list

# 3. Restore using the filtered list
./bin/pg_restore.sh myapp prod backups/myapp/prod/myapp_20260101_020000.dump --toc toc.list
```

### Refreshing a local or staging database from production

A common workflow: pull a production dump, strip large or sensitive tables, restore locally.

```bash
# Dump prod, skipping data for large/sensitive tables defined in exclude_data
./bin/pg_dump.sh myapp prod --with-excludes

# Restore into local
./bin/pg_restore.sh myapp local backups/myapp/prod/myapp_<timestamp>_exclude.dump --no-clean
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
