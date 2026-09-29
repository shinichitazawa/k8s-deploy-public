"""NetObserv のフローを FLP の write/grpc で受け取り、Iceberg の bronze テーブルに追記する。

FLP(flowlogs-pipeline)の gRPC writer は、フロー 1 件を JSON にして
genericmap.Flow{ genericMap: Any{ value: <JSON bytes> } } で送ってくる
(pkg/pipeline/write/write_grpc.go)。ここでは JSON を列に割り付けてバッファし、
一定時間または一定件数ごとに pyiceberg で append する。

S3 の鍵は持たない。Lakekeeper(REST カタログ)が vend する一時クレデンシャルだけで書く。
"""

import json
import logging
import os
import signal
import threading
import time
from concurrent import futures
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import grpc
import pyarrow as pa
from pyiceberg.catalog import load_catalog
from pyiceberg.exceptions import CommitFailedException
from pyiceberg.transforms import DayTransform

import genericmap_pb2

log = logging.getLogger("flow-ingest")
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")

CATALOG_URI = os.environ["ICEBERG_REST_URI"]
WAREHOUSE = os.environ.get("ICEBERG_WAREHOUSE", "lakehouse")
NAMESPACE = os.environ.get("ICEBERG_NAMESPACE", "bronze")
TABLE = os.environ.get("ICEBERG_TABLE", "netobserv_flows")
GRPC_PORT = int(os.environ.get("GRPC_PORT", "9999"))
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8080"))
FLUSH_SECONDS = int(os.environ.get("FLUSH_SECONDS", "60"))
FLUSH_ROWS = int(os.environ.get("FLUSH_ROWS", "20000"))
# 連続でこの回数失敗したら probe を落とす。
FAIL_STREAK_LIMIT = int(os.environ.get("FAIL_STREAK_LIMIT", "3"))
# 1 回の flush がこれだけ返ってこなければ、詰まったとみなして probe を落とす。
STALE_SECONDS = int(os.environ.get("STALE_SECONDS", str(max(FLUSH_SECONDS * 5, 300))))
# 書けないあいだ溜めておく上限。超えたぶんは古い行から捨てる。
MAX_BUFFER_ROWS = int(os.environ.get("MAX_BUFFER_ROWS", "100000"))

# Iceberg はコミットのたびに新しい metadata.json を積む。60 秒ごとに append すると
# 1 日 1,440 版になり、S3 のメタデータオブジェクトが際限なく増える(実測: 3,572
# スナップショットに対して metadata が 10,566 オブジェクト。データファイルは 34 個)。
# これはカタログ(Lakekeeper)ではなく Iceberg の仕様なので、テーブルプロパティで抑える。
# スナップショット自体は消えない(7 日の保持は expire_snapshots 側の話)。
TABLE_PROPERTIES = {
    "write.metadata.delete-after-commit.enabled": "true",
    "write.metadata.previous-versions-max": os.environ.get("METADATA_VERSIONS_MAX", "20"),
}

# FLP のフィールド名 → 列名と型。ここに無いキーは extra_json にまとめて残す。
# ms の時刻は timestamp(us) に、それ以外はそのまま。
FIELDS = [
    ("TimeFlowStartMs", "time_flow_start", pa.timestamp("us", tz="UTC")),
    ("TimeFlowEndMs", "time_flow_end", pa.timestamp("us", tz="UTC")),
    ("TimeReceived", "time_received", pa.timestamp("us", tz="UTC")),
    ("AgentIP", "agent_ip", pa.string()),
    ("SrcAddr", "src_addr", pa.string()),
    ("DstAddr", "dst_addr", pa.string()),
    ("SrcPort", "src_port", pa.int32()),
    ("DstPort", "dst_port", pa.int32()),
    ("Proto", "proto", pa.int32()),
    ("Etype", "etype", pa.int32()),
    ("Dscp", "dscp", pa.int32()),
    ("Flags", "flags", pa.int32()),
    ("Bytes", "bytes", pa.int64()),
    ("Packets", "packets", pa.int64()),
    ("Interfaces", "interfaces", pa.list_(pa.string())),
    ("IfDirections", "if_directions", pa.list_(pa.int32())),
    ("SrcK8S_Namespace", "src_k8s_namespace", pa.string()),
    ("SrcK8S_Name", "src_k8s_name", pa.string()),
    ("SrcK8S_Type", "src_k8s_type", pa.string()),
    ("SrcK8S_OwnerName", "src_k8s_owner_name", pa.string()),
    ("SrcK8S_OwnerType", "src_k8s_owner_type", pa.string()),
    ("SrcK8S_HostName", "src_k8s_host_name", pa.string()),
    ("SrcK8S_HostIP", "src_k8s_host_ip", pa.string()),
    ("DstK8S_Namespace", "dst_k8s_namespace", pa.string()),
    ("DstK8S_Name", "dst_k8s_name", pa.string()),
    ("DstK8S_Type", "dst_k8s_type", pa.string()),
    ("DstK8S_OwnerName", "dst_k8s_owner_name", pa.string()),
    ("DstK8S_OwnerType", "dst_k8s_owner_type", pa.string()),
    ("DstK8S_HostName", "dst_k8s_host_name", pa.string()),
    ("DstK8S_HostIP", "dst_k8s_host_ip", pa.string()),
    ("TimeFlowRttNs", "time_flow_rtt_ns", pa.int64()),
    ("DnsId", "dns_id", pa.int32()),
    ("DnsFlags", "dns_flags", pa.int32()),
    ("DnsLatencyMs", "dns_latency_ms", pa.int32()),
    ("DnsFlagsResponseCode", "dns_flags_response_code", pa.string()),
    ("DnsName", "dns_name", pa.string()),
    ("DnsErrno", "dns_errno", pa.int32()),
    ("IcmpType", "icmp_type", pa.int32()),
    ("IcmpCode", "icmp_code", pa.int32()),
    ("PktDropBytes", "pkt_drop_bytes", pa.int64()),
    ("PktDropPackets", "pkt_drop_packets", pa.int64()),
    ("PktDropLatestDropCause", "pkt_drop_latest_drop_cause", pa.string()),
    ("PktDropLatestState", "pkt_drop_latest_state", pa.string()),
    ("TcpRetransPackets", "tcp_retrans_packets", pa.int64()),
    ("TcpRetransBytes", "tcp_retrans_bytes", pa.int64()),
    ("SipMessages", "sip_messages", pa.int64()),
    ("SipRequests", "sip_requests", pa.int64()),
    ("SipResponses", "sip_responses", pa.int64()),
    ("SipLatestMethod", "sip_latest_method", pa.string()),
    ("SipLatestRespCode", "sip_latest_resp_code", pa.int32()),
]
# 値は取り込まないが、extra_json にも入れないキー(容量の割に使い道が無いもの)。
IGNORED = {"SrcMac", "DstMac", "SrcK8S_NetworkName", "DstK8S_NetworkName", "Udns", "PktDropLatestFlags"}
KNOWN = {src for src, _, _ in FIELDS}
SCHEMA = pa.schema([pa.field(col, typ, nullable=True) for _, col, typ in FIELDS] + [pa.field("extra_json", pa.string())])
MS_FIELDS = {"TimeFlowStartMs", "TimeFlowEndMs"}
S_FIELDS = {"TimeReceived"}


def to_row(flow: dict) -> dict:
    row = {}
    for src, col, _ in FIELDS:
        v = flow.get(src)
        if v is None:
            row[col] = None
        elif src in MS_FIELDS:
            row[col] = datetime.fromtimestamp(v / 1000, tz=timezone.utc)
        elif src in S_FIELDS:
            row[col] = datetime.fromtimestamp(v, tz=timezone.utc)
        else:
            row[col] = v
    extra = {k: v for k, v in flow.items() if k not in KNOWN and k not in IGNORED}
    row["extra_json"] = json.dumps(extra, separators=(",", ":")) if extra else None
    return row


class Sink:
    def __init__(self):
        self.catalog = load_catalog("lakekeeper", **{
            "type": "rest", "uri": CATALOG_URI, "warehouse": WAREHOUSE,
            "header.X-Iceberg-Access-Delegation": "vended-credentials",
        })
        # namespace もここで作る。これが無いと、カタログを作り直したときに
        # create_table が落ちて ArgoCD では復旧できない(silver / gold は SQLMesh が
        # namespace ごと作るので、bronze だけ手作業に依存していた)。既にあれば何もしない。
        if not self.catalog.namespace_exists(NAMESPACE):
            log.info("creating namespace %s", NAMESPACE)
            self.catalog.create_namespace(NAMESPACE)

        ident = (NAMESPACE, TABLE)
        if not self.catalog.table_exists(ident):
            log.info("creating table %s.%s", NAMESPACE, TABLE)
            t = self.catalog.create_table(ident, schema=SCHEMA, properties=TABLE_PROPERTIES)
            with t.update_spec() as spec:
                spec.add_field("time_flow_start", DayTransform(), "time_flow_start_day")
        self.table = self.catalog.load_table(ident)
        # 既にあるテーブルにもプロパティを当てる(作り直さずに済ませるため)。
        missing_props = {k: v for k, v in TABLE_PROPERTIES.items() if self.table.properties.get(k) != v}
        if missing_props:
            log.info("setting table properties: %s", missing_props)
            with self.table.transaction() as tx:
                tx.set_properties(**missing_props)
            self.table = self.catalog.load_table(ident)

        # FIELDS に列を足したら、既存テーブルにも足す。union_by_name は追加だけで、
        # 既存の列を消したり型を変えたりはしない(消したい場合は人間が手で流す)。
        existing = set(self.table.schema().column_names)
        missing = [f for f in SCHEMA.names if f not in existing]
        if missing:
            log.info("adding columns to %s.%s: %s", NAMESPACE, TABLE, ", ".join(missing))
            with self.table.update_schema() as us:
                us.union_by_name(SCHEMA)
            self.table = self.catalog.load_table(ident)
        self.lock = threading.Lock()
        self.buf: list[dict] = []
        self.stats = {"received": 0, "written": 0, "flushes": 0, "failed_flushes": 0, "dropped": 0, "last_flush": None, "last_error": None}
        self.last_flush = time.monotonic()
        self.next_attempt = 0.0  # 失敗したら次に試してよい時刻(monotonic)
        self.fail_streak = 0
        self.flush_started: float | None = None  # flush 実行中だけ値が入る

    def wedged(self) -> bool:
        """1 回の flush が STALE_SECONDS 返ってこない = プロセスが詰まっている。

        **書けないこと(Lakekeeper の障害など)はここに含めない。** probe を落とすと pod が
        入れ替わり、バッファに抱えた行が失われる。そのうえ入れ替えても障害は直らない。
        詰まっている場合だけは、待っても復帰しないので入れ替える価値がある。
        """
        started = self.flush_started
        return started is not None and time.monotonic() - started >= STALE_SECONDS

    def degraded(self) -> bool:
        """連続で書けていない。probe には出さず、状態として見せるだけ。"""
        return self.fail_streak >= FAIL_STREAK_LIMIT

    def add(self, row: dict):
        with self.lock:
            self.buf.append(row)
            self.stats["received"] += 1
            full = len(self.buf) >= FLUSH_ROWS
        # 失敗して行を戻した直後はバッファが上限のままなので、そのまま呼ぶと 1 行ごとに
        # 再試行してしまう。next_attempt で間隔を空ける。例外は flush_safely が受ける
        # (ここで投げると gRPC の送り主に「不正なフロー」として返ってしまう)。
        if full and time.monotonic() >= self.next_attempt:
            self.flush_safely()

    def flush(self):
        with self.lock:
            if not self.buf:
                self.last_flush = time.monotonic()
                return
            rows, self.buf = self.buf, []
        self.flush_started = time.monotonic()
        try:
            self._append(rows)
        except Exception:
            # 書けなかった行はバッファの先頭に戻す(上限を超えたぶんは古い方から捨てる)。
            with self.lock:
                self.buf = rows + self.buf
                if len(self.buf) > MAX_BUFFER_ROWS:
                    dropped = len(self.buf) - MAX_BUFFER_ROWS
                    self.buf = self.buf[dropped:]
                    self.stats["dropped"] += dropped
                    log.error("buffer full: dropped %d oldest rows", dropped)
            raise
        finally:
            self.flush_started = None

    def _append(self, rows: list[dict]):
        tbl = pa.Table.from_pylist(rows, schema=SCHEMA)
        # 毎回読み直す。Lakekeeper が vend する S3 の一時クレデンシャルは 1 時間で切れるが、
        # pyiceberg 0.12.0 は自動更新しない(client.refresh-credentials-endpoint を実装していない。
        # apache/iceberg-python#3506 / #3751 が未実装の feature request)。読み直すと vend し直される。
        # ついでに他の書き手(compaction)のコミットも取り込むので、競合しにくくなる。
        self.table = self.catalog.load_table((NAMESPACE, TABLE))
        for attempt in (1, 2):
            try:
                self.table.append(tbl)
                break
            except CommitFailedException as e:
                # 別の書き手(Trino の optimize など)と競合したら、最新のメタデータを読み直して 1 回だけやり直す
                log.warning("commit conflict (attempt %d): %s", attempt, e)
                self.table = self.catalog.load_table((NAMESPACE, TABLE))
                if attempt == 2:
                    raise
        self.stats["written"] += tbl.num_rows
        self.stats["flushes"] += 1
        self.stats["last_flush"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        self.last_flush = time.monotonic()
        self.fail_streak = 0
        log.info("appended %d rows (%d bytes parquet-in)", tbl.num_rows, tbl.nbytes)

    def flush_safely(self):
        try:
            self.flush()
        except Exception as e:  # noqa: BLE001 — 落とさず次の周期でやり直す(行はバッファに戻してある)
            self.fail_streak += 1
            self.stats["failed_flushes"] += 1
            self.stats["last_error"] = f"{type(e).__name__}: {e}"[:300]
            log.error("flush failed (streak %d): %s", self.fail_streak, e)
        finally:
            # 失敗しても次の周期まで待つ(1 秒ごとに叩き直さない)。
            self.last_flush = time.monotonic()
            self.next_attempt = self.last_flush + (FLUSH_SECONDS if self.fail_streak else 0)


class Collector:
    """genericmap.Collector サービス。生成コードを使わず generic handler で実装する。"""

    def __init__(self, sink: Sink):
        self.sink = sink

    def send(self, request: genericmap_pb2.Flow, context) -> genericmap_pb2.CollectorReply:
        try:
            row = to_row(json.loads(request.genericMap.value))
        except Exception as e:  # noqa: BLE001 — ここに来るのは中身が壊れているときだけ
            log.warning("bad flow: %s", e)
            context.abort(grpc.StatusCode.INVALID_ARGUMENT, str(e))
        self.sink.add(row)  # 書き込みの失敗は add の中で握る(送り主には返さない)
        return genericmap_pb2.CollectorReply()

    def handler(self) -> grpc.GenericRpcHandler:
        return grpc.method_handlers_generic_handler("genericmap.Collector", {
            "Send": grpc.unary_unary_rpc_method_handler(
                self.send,
                request_deserializer=genericmap_pb2.Flow.FromString,
                response_serializer=genericmap_pb2.CollectorReply.SerializeToString,
            ),
        })


def http_server(sink: Sink):
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            wedged = sink.wedged()
            if self.path.rstrip("/") == "/livez":
                # probe 用。詰まっているときだけ落とす。
                body, code = (b"wedged\n", 503) if wedged else (b"ok\n", 200)
                ctype = "text/plain"
            else:
                body = json.dumps({
                    **sink.stats, "buffered": len(sink.buf), "fail_streak": sink.fail_streak,
                    "degraded": sink.degraded(), "wedged": wedged,
                }).encode()
                code, ctype = 200, "application/json"
            self.send_response(code)
            self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
            self.end_headers(); self.wfile.write(body)
        def log_message(self, *a): pass
    return ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), H)


def main():
    sink = Sink()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8), handlers=[Collector(sink).handler()])
    server.add_insecure_port(f"0.0.0.0:{GRPC_PORT}")
    server.start()
    hs = http_server(sink); threading.Thread(target=hs.serve_forever, daemon=True).start()
    log.info("listening grpc=%d http=%d flush every %ds or %d rows", GRPC_PORT, HTTP_PORT, FLUSH_SECONDS, FLUSH_ROWS)

    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    while not stop.wait(1):
        if time.monotonic() - sink.last_flush >= FLUSH_SECONDS:
            sink.flush_safely()
    log.info("stopping: draining")
    server.stop(5).wait()
    sink.flush_safely()


if __name__ == "__main__":
    main()
