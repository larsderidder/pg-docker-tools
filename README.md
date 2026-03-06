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

## Shipping dumps to S3

`pg_ship.sh` uploads a dump file or directory to any S3-compatible store: AWS S3, [Garage](https://garagehq.deuxfleurs.fr/), Tigris, Cloudflare R2, etc.

### Requirements

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- S3 credentials in the environment: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`

### Configure

Add a `ship` block to `config.yaml`:

```yaml
ship:
  bucket: my-backups
  prefix: pgbackups            # key prefix inside the bucket (default: pgbackups)
  endpoint: https://s3.garage.example.com   # omit for AWS S3
```

Or pass flags directly — no config needed.

### Usage

```bash
# Ship a dump, read bucket/endpoint from config.yaml
pg_ship.sh backups/app/prod/app_20260101_020000.dump

# Ship to a specific bucket on AWS S3
pg_ship.sh backups/app/prod/app_20260101_020000.dump \
  --bucket my-backups --prefix pgbackups/app/prod

# Ship to Garage (or R2, Tigris, etc.)
pg_ship.sh backups/app/prod/app_20260101_020000.dump \
  --bucket my-backups \
  --endpoint https://s3.garage.example.com

# Ship and remove the local file after upload
pg_ship.sh backups/app/prod/app_20260101_020000.dump --delete-after
```

The `.sha256` checksum file is uploaded alongside the dump automatically. Pass `--no-checksum` to skip it.

## Fetching dumps from S3

`pg_fetch.sh` downloads a dump from any S3-compatible store back to a local path. It is the complement to `pg_ship.sh`.

```bash
# Fetch using bucket/endpoint from config.yaml
pg_fetch.sh pgbackups/app/prod/app_20260101_020000.dump --config config.yaml

# Fetch from AWS S3 with explicit bucket, save to backups/
pg_fetch.sh pgbackups/app/prod/app_20260101_020000.dump \
  --bucket my-backups --output backups/app/prod/

# Fetch from Garage (or R2, Tigris, etc.)
pg_fetch.sh pgbackups/app/prod/app_20260101_020000.dump \
  --bucket my-backups \
  --endpoint https://s3.garage.example.com \
  --output backups/app/prod/

# Fetch using a full s3:// URI
pg_fetch.sh s3://my-backups/pgbackups/app/prod/app_20260101_020000.dump
```

The `.sha256` checksum is downloaded and verified automatically. Pass `--no-checksum` to skip.

### Fetch and restore in one go

```bash
./bin/pg_fetch.sh pgbackups/app/prod/app_20260101_020000.dump \
  --config config.yaml --output backups/app/prod/
./bin/pg_restore.sh app local backups/app/prod/app_20260101_020000.dump --no-clean
```

### Dump and ship in one go

```bash
./bin/pg_dump.sh app prod --keep-days 7
./bin/pg_ship.sh backups/app/prod/app_$(date +%Y%m%d)_*.dump --delete-after
```

Or in a cron job:

```bash
0 2 * * * deploy \
  PGPASSWORD_APP_PROD=secret /opt/pgtools/bin/pg_dump.sh app prod --keep-days 7 \
  && AWS_ACCESS_KEY_ID=key AWS_SECRET_ACCESS_KEY=secret \
     /opt/pgtools/bin/pg_ship.sh "$(ls -1t /opt/pgtools/backups/app/prod/*.dump | head -1)" \
     --delete-after \
  >> /var/log/pgtools.log 2>&1
```

### Setting up Garage

[Garage](https://garagehq.deuxfleurs.fr/) is a lightweight self-hosted S3-compatible store, useful if you want off-machine backups without a cloud dependency.

1. [Install and start Garage](https://garagehq.deuxfleurs.fr/documentation/quick-start/)
2. Create a bucket and access key:

```bash
garage bucket create pg-backups
garage key create pg-backup-key
garage bucket allow pg-backups --read --write --key pg-backup-key
```

3. Export credentials and ship:

```bash
export AWS_ACCESS_KEY_ID=<key-id>
export AWS_SECRET_ACCESS_KEY=<secret>
export AWS_DEFAULT_REGION=garage   # any non-empty string works

./bin/pg_ship.sh backups/app/prod/app_20260101_020000.dump \
  --bucket pg-backups \
  --endpoint http://localhost:3900
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
larsderidder/pg-docker-tools:0.1.0
larsderidder/pg-docker-tools:latest
```
