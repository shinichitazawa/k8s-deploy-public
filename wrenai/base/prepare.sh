#!/bin/sh
# initContainer: wrenai を emptyDir に入れ、ConfigMap の MDL プロジェクトを展開して build する。
set -eu

# pip は wheel を TMPDIR に展開する。/tmp(emptyDir 256Mi)だと超過して pod が evict される
# (初回デプロイで実際に起きた)。容量のある site 用 emptyDir の下を使い、終わったら消す。
export TMPDIR=/opt/wren/.piptmp
mkdir -p "$TMPDIR"

pip install --no-cache-dir --disable-pip-version-check \
  --require-hashes --only-binary :all: \
  --target /opt/wren -r /config/requirements.lock
rm -rf "$TMPDIR"

# ConfigMap のキーに "/" は使えないので "__" で区切ってある。ディレクトリ構造に戻す。
for f in /config-project/*; do
  rel=$(basename "$f" | sed 's|__|/|g')
  mkdir -p "/work/project/$(dirname "$rel")"
  cp "$f" "/work/project/$rel"
done

mkdir -p /work/home
cp /config/profiles.yml /work/home/profiles.yml

export PYTHONPATH=/opt/wren PATH="/opt/wren/bin:$PATH"
wren context build --path /work/project
