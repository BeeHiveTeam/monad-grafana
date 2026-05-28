"""
Monad RPC sidecar exporter for Prometheus.

Exposes :9101/metrics with:
  - monad_local_block_number / monad_public_block_number / monad_sync_gap_blocks
  - monad_last_block_age_seconds / monad_last_block_timestamp
  - monad_rpc_local_up / monad_rpc_public_up
  - monad_service_uptime_seconds{service="monad-bft|monad-execution|monad-rpc"}

Configuration via environment:
  LOCAL_RPC_URL   — Monad node JSON-RPC endpoint (default: http://host.docker.internal:8080)
  PUBLIC_RPC_URL  — public testnet RPC for sync-gap reference (default: https://testnet-rpc.monad.xyz)

Service uptime requires container running with `pid: host` to read /proc/<pid>/stat
of monad-* processes on the host.
"""
import json, urllib.request, time, threading, os
from http.server import HTTPServer, BaseHTTPRequestHandler

LOCAL_RPC_URL = os.environ.get('LOCAL_RPC_URL', 'http://host.docker.internal:8080')
PUBLIC_RPC_URL = os.environ.get('PUBLIC_RPC_URL', 'https://testnet-rpc.monad.xyz')

state = {
    'local': 0, 'public': 0, 'local_ok': 0, 'public_ok': 0,
    'last_block_ts': 0, 'updated_at': 0,
    # chain_match: 1 = local and public RPC are the same network, 0 = mismatch,
    # -1 = not yet determined / a chain_id probe failed. The sync-gap metric is
    # only meaningful when chain_match == 1.
    'chain_match': -1,
    'uptime': {}
}

def _rpc(url, method, params=None):
    req = urllib.request.Request(url,
        data=json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params or []}).encode(),
        headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())['result']

def fetch_block_number(url):
    return int(_rpc(url, "eth_blockNumber"), 16)

def fetch_chain_id(url):
    return int(_rpc(url, "eth_chainId"), 16)

def fetch_block_ts(url, blk_hex):
    req = urllib.request.Request(url,
        data=json.dumps({"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":[blk_hex, False]}).encode(),
        headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=5) as r:
        b = json.loads(r.read())['result']
        return int(b['timestamp'], 16) if b else 0

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path != '/metrics':
            self.send_error(404); return
        # Only report a sync gap when local and public RPC are the same network.
        # Comparing block heights across different chains (e.g. a mainnet node vs
        # the testnet public RPC default) yields a meaningless gap that would
        # trip false stall/lag alerts.
        gap = (state['public'] - state['local']
               if state['local'] and state['public'] and state['chain_match'] == 1
               else 0)
        block_age = max(0, int(time.time()) - state['last_block_ts']) if state['last_block_ts'] else 0
        body = (
            "# HELP monad_local_block_number Block height of our node\n# TYPE monad_local_block_number gauge\n"
            f"monad_local_block_number {state['local']}\n"
            "# HELP monad_public_block_number Block height of public testnet RPC\n# TYPE monad_public_block_number gauge\n"
            f"monad_public_block_number {state['public']}\n"
            "# HELP monad_sync_gap_blocks Public minus local (positive = we lag)\n# TYPE monad_sync_gap_blocks gauge\n"
            f"monad_sync_gap_blocks {gap}\n"
            "# HELP monad_rpc_local_up Local RPC responded last cycle\n# TYPE monad_rpc_local_up gauge\n"
            f"monad_rpc_local_up {state['local_ok']}\n"
            "# HELP monad_rpc_public_up Public RPC responded last cycle\n# TYPE monad_rpc_public_up gauge\n"
            f"monad_rpc_public_up {state['public_ok']}\n"
            "# HELP monad_rpc_network_mismatch 1 if local and public RPC are different chains (sync gap suppressed), 0 if same, -1 unknown\n# TYPE monad_rpc_network_mismatch gauge\n"
            f"monad_rpc_network_mismatch {0 if state['chain_match'] == 1 else (1 if state['chain_match'] == 0 else -1)}\n"
            "# HELP monad_rpc_exporter_updated_seconds Unix ts of last update\n# TYPE monad_rpc_exporter_updated_seconds gauge\n"
            f"monad_rpc_exporter_updated_seconds {state['updated_at']}\n"
            "# HELP monad_last_block_age_seconds Seconds since latest block was produced (on-chain timestamp)\n# TYPE monad_last_block_age_seconds gauge\n"
            f"monad_last_block_age_seconds {block_age}\n"
            "# HELP monad_last_block_timestamp Unix ts of latest block (on-chain)\n# TYPE monad_last_block_timestamp gauge\n"
            f"monad_last_block_timestamp {state['last_block_ts']}\n"
            "# HELP monad_service_uptime_seconds Uptime of monad-* systemd service\n# TYPE monad_service_uptime_seconds gauge\n"
        )
        now = int(time.time())
        for svc, started in state['uptime'].items():
            if started > 0:
                body += f'monad_service_uptime_seconds{{service="{svc}"}} {now - started}\n'
        self.send_response(200); self.send_header('Content-Type','text/plain; version=0.0.4'); self.end_headers()
        self.wfile.write(body.encode())

def updater_blocks():
    while True:
        try:
            n = fetch_block_number(LOCAL_RPC_URL)
            state['local'] = n; state['local_ok'] = 1
            try:
                ts = fetch_block_ts(LOCAL_RPC_URL, hex(n))
                if ts: state['last_block_ts'] = ts
            except Exception: pass
        except Exception: state['local_ok'] = 0
        try:
            state['public'] = fetch_block_number(PUBLIC_RPC_URL); state['public_ok'] = 1
        except Exception: state['public_ok'] = 0
        # Verify local and public RPC are the same network before trusting the
        # sync gap. A chain_id probe failure leaves chain_match unknown (-1).
        if state['local_ok'] and state['public_ok']:
            try:
                state['chain_match'] = 1 if fetch_chain_id(LOCAL_RPC_URL) == fetch_chain_id(PUBLIC_RPC_URL) else 0
            except Exception:
                state['chain_match'] = -1
        state['updated_at'] = int(time.time())
        time.sleep(10)

def updater_uptime():
    # Requires `pid: host` in docker-compose to access host /proc.
    # Maps systemd service name → comm (process name in /proc/<pid>/comm).
    services = [
        ('monad-bft', 'monad-node'),
        ('monad-execution', 'monad'),
        ('monad-rpc', 'monad-rpc'),
    ]
    while True:
        for svc, comm_pattern in services:
            try:
                for pid_dir in os.listdir('/proc'):
                    if not pid_dir.isdigit(): continue
                    try:
                        comm = open(f'/proc/{pid_dir}/comm').read().strip()
                        if comm != comm_pattern: continue
                        stat = open(f'/proc/{pid_dir}/stat').read().split()
                        start_ticks = int(stat[21])  # field 22 (0-indexed)
                        btime = 0
                        for line in open('/proc/stat'):
                            if line.startswith('btime '):
                                btime = int(line.split()[1]); break
                        hz = os.sysconf(os.sysconf_names['SC_CLK_TCK'])
                        state['uptime'][svc] = btime + start_ticks // hz
                        break
                    except (FileNotFoundError, PermissionError, ProcessLookupError):
                        continue
            except Exception:
                pass
        time.sleep(30)

threading.Thread(target=updater_blocks, daemon=True).start()
threading.Thread(target=updater_uptime, daemon=True).start()
HTTPServer(('0.0.0.0', 9101), H).serve_forever()
