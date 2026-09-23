#!/bin/bash
set -e

echo "host replication replicator 172.16.0.0/12 scram-sha-256" >> "$PGDATA/pg_hba.conf"
