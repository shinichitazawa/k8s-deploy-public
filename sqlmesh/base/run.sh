#!/bin/sh
# 1) git のモデル定義を反映(差分が無ければ何もしない)
# 2) 期限の来た区間を埋める
set -eu
export PYTHONPATH=/opt/app PATH="/opt/app/bin:$PATH"
cd /work/project

# PG のロール名は "sqlmesh.sqlmesh"。Secret の username をそのまま使う。
export PGUSER PGPASSWORD

echo "=== sqlmesh plan prod"
sqlmesh plan prod --no-prompts --auto-apply
echo "=== sqlmesh run"
sqlmesh run
