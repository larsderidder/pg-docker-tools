# Kubernetes reference deployment

This directory contains reference manifests for running periodic backups and one-off backup/restore jobs.

## What’s included

- `configmap.yaml`: Mounts `config.yaml` for the scripts.
- `secret.yaml`: Placeholder for PGPASSWORD variables.
- `cronjob-backup.yaml`: Periodic backup CronJob.
- `job-backup.yaml`: One-off backup Job.
- `job-restore.yaml`: One-off restore Job.
- `pvc.yaml`: Persistent volume claim for storing backups.

## Notes

- These manifests assume a container image that includes:
  - `pg_dump.sh`, `pg_restore.sh`, `confirm_env.sh`
  - `yq` (v4)
  - `postgres` client tools matching your `pg_version`
- The Job/CronJob manifests default to `pg-docker-tools:latest`; change if needed.
- Backups are written to `/work/backups` on a PVC.

## Apply

```bash
kubectl apply -f k8s/pvc.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/cronjob-backup.yaml
```

## Run one-off jobs

```bash
kubectl apply -f k8s/job-backup.yaml
kubectl apply -f k8s/job-restore.yaml
```
