#!/bin/sh
# initContainer: 依存を emptyDir に入れ、ConfigMap のプロジェクトを展開する。
set -eu

# pip は wheel を TMPDIR に展開する。/tmp(256Mi)では足りないので容量のある側を使う。
export TMPDIR=/opt/app/.piptmp
mkdir -p "$TMPDIR"
pip install --no-cache-dir --disable-pip-version-check \
  --require-hashes --only-binary :all: \
  --target /opt/app -r /config/requirements.lock
rm -rf "$TMPDIR"

# ConfigMap のキーに "/" は使えないので "__" で区切ってある。ディレクトリ構造に戻す。
mkdir -p /work/project
for f in /config-project/*; do
  rel=$(basename "$f" | sed 's|__|/|g')
  mkdir -p "/work/project/$(dirname "$rel")"
  cp "$f" "/work/project/$rel"
done
cp /config/config.yaml /work/project/config.yaml
