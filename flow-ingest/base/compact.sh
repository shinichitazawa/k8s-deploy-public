#!/bin/bash
# Iceberg テーブルの小さいファイルをまとめ、古いスナップショットと孤立ファイルを片付ける。
# Trino の REST API を直接叩く(CLI の jar を持ち込まないため)。
set -uo pipefail

: "${TRINO_URL:?}" "${TRINO_CATALOG:?}" "${TRINO_SCHEMA:?}" "${TABLES:?}"
TRINO_USER="${TRINO_USER:-flow-compact}"

run_sql() {
  local sql="$1" resp next err state
  resp=$(curl -sS --fail-with-body -X POST \
    -H "X-Trino-User: $TRINO_USER" -H "X-Trino-Catalog: $TRINO_CATALOG" -H "X-Trino-Schema: $TRINO_SCHEMA" \
    -H "X-Trino-Source: flow-compact" --data-binary "$sql" "$TRINO_URL/v1/statement") || {
      echo "  POST failed: $resp" >&2; return 1; }
  while :; do
    err=$(printf '%s' "$resp" | jq -r '.error.message // empty')
    if [ -n "$err" ]; then echo "  query failed: $err" >&2; return 1; fi
    state=$(printf '%s' "$resp" | jq -r '.stats.state // empty')
    next=$(printf '%s' "$resp" | jq -r '.nextUri // empty')
    [ -z "$next" ] && break
    sleep 0.5
    resp=$(curl -sS --fail-with-body -H "X-Trino-User: $TRINO_USER" "$next") || {
      echo "  GET failed: $resp" >&2; return 1; }
  done
  echo "  done (last state: ${state:-unknown})"
}

files() {  # 1 行 "<ファイル数> <合計バイト>" を返す
  local t="$1" resp next out=""
  resp=$(curl -sS -X POST -H "X-Trino-User: $TRINO_USER" -H "X-Trino-Catalog: $TRINO_CATALOG" \
    -H "X-Trino-Schema: $TRINO_SCHEMA" --data-binary \
    "SELECT count(*), coalesce(sum(file_size_in_bytes),0) FROM \"$t\$files\"" "$TRINO_URL/v1/statement")
  while :; do
    out="$(printf '%s' "$resp" | jq -r '.data[0] // empty | @tsv')${out}"
    next=$(printf '%s' "$resp" | jq -r '.nextUri // empty'); [ -z "$next" ] && break
    sleep 0.3; resp=$(curl -sS -H "X-Trino-User: $TRINO_USER" "$next")
  done
  echo "$out"
}

rc=0
for t in $TABLES; do
  echo "== $t"
  before=$(files "$t"); echo "  before: ${before:-?} (files, bytes)"
  for sql in \
    "ALTER TABLE $t EXECUTE optimize" \
    "ALTER TABLE $t EXECUTE expire_snapshots(retention_threshold => '${SNAPSHOT_RETENTION:-7d}')" \
    "ALTER TABLE $t EXECUTE remove_orphan_files(retention_threshold => '${ORPHAN_RETENTION:-7d}')"
  do
    echo "  $sql"
    run_sql "$sql" || rc=1
  done
  after=$(files "$t"); echo "  after : ${after:-?} (files, bytes)"
done
exit $rc
