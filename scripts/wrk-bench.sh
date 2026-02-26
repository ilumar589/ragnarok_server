#!/usr/bin/env bash
# ─────────────────────────────────────────────────────
# wrk-bench.sh — Run wrk benchmarks against Ragnarok
# ─────────────────────────────────────────────────────
#
# Usage (inside Docker):
#   /app/scripts/wrk-bench.sh
#
# Usage (host, server already running):
#   HOST=localhost PORT=8080 ./scripts/wrk-bench.sh
#
# Outputs:
#   Console summary + /app/reports/wrk_report.html
#
set -uo pipefail

HOST="${HOST:-localhost}"
PORT="${PORT:-8080}"
BASE_URL="http://${HOST}:${PORT}"
DURATION="${DURATION:-10s}"
WRK_THREADS="${WRK_THREADS:-4}"
REPORT_DIR="${REPORT_DIR:-/app/reports}"
REPORT_FILE="${REPORT_DIR}/wrk_report.html"

CONCURRENCY_LEVELS=(1 8 32 64 128 256)
ENDPOINTS=("/plaintext" "/json")

SERVER_PID=""

# ── Helpers ──────────────────────────────────────────

cleanup() {
    if [[ -n "${SERVER_PID}" ]]; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

wait_for_server() {
    local max_wait=150
    local waited=0
    echo "  Waiting for server at ${BASE_URL}..."
    while ! curl -sf "${BASE_URL}/plaintext" > /dev/null 2>&1; do
        sleep 0.2
        waited=$((waited + 1))
        if [[ ${waited} -ge ${max_wait} ]]; then
            echo "  ERROR: Server did not start within 30s"
            exit 1
        fi
    done
    echo "  Server is ready."
}

# Start the server if not already running
start_server_if_needed() {
    if curl -sf "${BASE_URL}/plaintext" > /dev/null 2>&1; then
        echo "  Server already running at ${BASE_URL}"
        return
    fi

    if [[ -x /app/ragnarok ]]; then
        echo "  Starting Ragnarok server..."
        /app/ragnarok > /dev/null 2>&1 &
        SERVER_PID=$!
        wait_for_server
    else
        echo "  ERROR: Server not running and /app/ragnarok not found."
        echo "  Either start the server first or run inside the Docker container."
        exit 1
    fi
}

# Restart the server (e.g. after a crash)
ensure_server_running() {
    if [[ -n "${SERVER_PID}" ]] && ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        echo "  [!] Server crashed — restarting..."
        /app/ragnarok > /dev/null 2>&1 &
        SERVER_PID=$!
        # Wait up to 10s for the restart
        local waited=0
        while ! curl -sf "${BASE_URL}/plaintext" > /dev/null 2>&1; do
            sleep 0.2
            waited=$((waited + 1))
            if [[ ${waited} -ge 50 ]]; then
                echo "  [!] Server restart failed — skipping this run"
                return 1
            fi
        done
        echo "  [!] Server restarted OK"
    fi
    return 0
}

# ── Results storage ──────────────────────────────────

# CSV-like storage: endpoint,concurrency,req_s,avg_latency,p50,p75,p90,p99,max_latency,transfer_s
RESULTS_FILE=$(mktemp)

run_wrk() {
    local endpoint="$1"
    local concurrency="$2"
    local url="${BASE_URL}${endpoint}"
    local threads=${WRK_THREADS}

    # Threads can't exceed connections
    if [[ ${concurrency} -lt ${threads} ]]; then
        threads=${concurrency}
    fi

    echo "  wrk -t${threads} -c${concurrency} -d${DURATION} --latency ${url}"
    local output
    output=$(wrk -t"${threads}" -c"${concurrency}" -d"${DURATION}" --latency "${url}" 2>&1) || true

    # Parse wrk output
    local req_s avg_lat p50 p75 p90 p99 max_lat transfer_s

    req_s=$(echo "${output}" | grep "Requests/sec:" | awk '{print $2}')
    transfer_s=$(echo "${output}" | grep "Transfer/sec:" | awk '{print $2}')
    avg_lat=$(echo "${output}" | grep "Latency" | head -1 | awk '{print $2}')

    # Latency distribution lines: 50% xx, 75% xx, 90% xx, 99% xx
    p50=$(echo "${output}" | awk '/Latency Distribution/{found=1; next} found && /50%/{print $2; exit}')
    p75=$(echo "${output}" | awk '/Latency Distribution/{found=1; next} found && /75%/{print $2; exit}')
    p90=$(echo "${output}" | awk '/Latency Distribution/{found=1; next} found && /90%/{print $2; exit}')
    p99=$(echo "${output}" | awk '/Latency Distribution/{found=1; next} found && /99%/{print $2; exit}')
    max_lat=$(echo "${output}" | grep "Latency" | head -1 | awk '{print $4}')

    # Default empty values
    req_s="${req_s:-0}"
    transfer_s="${transfer_s:-0B}"
    avg_lat="${avg_lat:-0}"
    p50="${p50:-0}"
    p75="${p75:-0}"
    p90="${p90:-0}"
    p99="${p99:-0}"
    max_lat="${max_lat:-0}"

    echo "${endpoint},${concurrency},${req_s},${avg_lat},${p50},${p75},${p90},${p99},${max_lat},${transfer_s}" >> "${RESULTS_FILE}"

    printf "    %-12s  %10s req/s  avg=%s  p50=%s  p99=%s  max=%s\n" \
        "c=${concurrency}" "${req_s}" "${avg_lat}" "${p50}" "${p99}" "${max_lat}"
}

# ── Main ─────────────────────────────────────────────

echo "========================================================="
echo "  Ragnarok HTTP — wrk Benchmark Suite"
echo "========================================================="
echo ""

start_server_if_needed
echo ""

mkdir -p "${REPORT_DIR}"

for endpoint in "${ENDPOINTS[@]}"; do
    echo "── ${endpoint} ──────────────────────────────────────"
    for c in "${CONCURRENCY_LEVELS[@]}"; do
        if ! ensure_server_running; then
            echo "    c=${c}  SKIPPED (server unavailable)"
            echo "${endpoint},${c},0,0,0,0,0,0,0,0" >> "${RESULTS_FILE}"
            continue
        fi
        sleep 0.5
        run_wrk "${endpoint}" "${c}"
    done
    echo ""
done

echo "========================================================="
echo "  Generating HTML report..."

# ── HTML Report ──────────────────────────────────────

cat > "${REPORT_FILE}" <<'HEADER'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Ragnarok HTTP — wrk Benchmark Report</title>
<style>
  :root {
    --bg: #0d1117; --surface: #161b22; --border: #30363d;
    --text: #e6edf3; --muted: #8b949e; --accent: #58a6ff;
    --green: #3fb950; --orange: #d29922; --red: #f85149;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); padding: 2rem; line-height: 1.5;
  }
  h1 { font-size: 1.75rem; margin-bottom: 0.25rem; }
  .subtitle { color: var(--muted); margin-bottom: 2rem; font-size: 0.9rem; }
  .summary-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 1rem; margin-bottom: 2rem;
  }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; padding: 1rem;
  }
  .card .label { font-size: 0.75rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
  .card .value { font-size: 1.5rem; font-weight: 700; margin-top: 0.25rem; font-family: 'SF Mono', 'Cascadia Code', Consolas, monospace; }
  .card .unit { font-size: 0.8rem; color: var(--muted); }
  .category { margin-bottom: 2.5rem; }
  .category h2 {
    font-size: 1.1rem; color: var(--accent); border-bottom: 1px solid var(--border);
    padding-bottom: 0.5rem; margin-bottom: 1rem;
  }
  table {
    width: 100%; border-collapse: collapse; font-size: 0.85rem;
    background: var(--surface); border-radius: 8px; overflow: hidden;
  }
  th {
    text-align: left; padding: 0.6rem 1rem; background: var(--border);
    color: var(--muted); font-weight: 600; font-size: 0.75rem;
    text-transform: uppercase; letter-spacing: 0.05em;
  }
  td { padding: 0.6rem 1rem; border-top: 1px solid var(--border); }
  tr:hover td { background: rgba(88,166,255,0.04); }
  .num { text-align: right; font-variant-numeric: tabular-nums; font-family: 'SF Mono', 'Cascadia Code', Consolas, monospace; }
  .bar-cell { width: 120px; }
  .bar-bg { background: var(--border); border-radius: 4px; height: 8px; }
  .bar-fill { height: 8px; border-radius: 4px; background: var(--green); }
  footer { margin-top: 3rem; color: var(--muted); font-size: 0.75rem; text-align: center; }
</style>
</head>
<body>
<h1>Ragnarok HTTP — wrk Benchmark Report</h1>
HEADER

echo "<p class=\"subtitle\">Generated $(date -u '+%Y-%m-%d %H:%M:%S UTC') &mdash; wrk ${DURATION} per test, ${WRK_THREADS} threads</p>" >> "${REPORT_FILE}"

# Summary cards: find peak req/s and best p99
peak_reqs=$(awk -F',' '{if($3+0 > max) max=$3+0} END{printf "%.0f", max}' "${RESULTS_FILE}")
best_p99=$(awk -F',' '{print $8}' "${RESULTS_FILE}" | grep -v '^0$' | head -1)

# Find peak for each endpoint
peak_plaintext=$(awk -F',' '$1=="/plaintext"{if($3+0>max) max=$3+0} END{printf "%.0f", max}' "${RESULTS_FILE}")
peak_json=$(awk -F',' '$1=="/json"{if($3+0>max) max=$3+0} END{printf "%.0f", max}' "${RESULTS_FILE}")

cat >> "${REPORT_FILE}" <<EOF
<div class="summary-grid">
  <div class="card"><div class="label">Peak Req/sec (Plaintext)</div><div class="value">${peak_plaintext} <span class="unit">req/s</span></div></div>
  <div class="card"><div class="label">Peak Req/sec (JSON)</div><div class="value">${peak_json} <span class="unit">req/s</span></div></div>
  <div class="card"><div class="label">Overall Peak</div><div class="value">${peak_reqs} <span class="unit">req/s</span></div></div>
  <div class="card"><div class="label">Concurrency Levels</div><div class="value">${#CONCURRENCY_LEVELS[@]}</div></div>
  <div class="card"><div class="label">Duration / Test</div><div class="value">${DURATION}</div></div>
</div>
EOF

# Generate table for each endpoint
for endpoint in "${ENDPOINTS[@]}"; do
    label=$(echo "${endpoint}" | sed 's/\///' | sed 's/^./\U&/')

    # Find max req/s for this endpoint (for relative bar)
    max_reqs=$(awk -F',' -v ep="${endpoint}" '$1==ep{if($3+0>max) max=$3+0} END{printf "%.0f", max}' "${RESULTS_FILE}")

    cat >> "${REPORT_FILE}" <<EOF
<div class="category">
<h2>${label} — ${endpoint}</h2>
<table>
<thead><tr>
  <th class="num">Connections</th>
  <th class="num">Req/sec</th>
  <th class="num">Avg Latency</th>
  <th class="num">P50</th>
  <th class="num">P75</th>
  <th class="num">P90</th>
  <th class="num">P99</th>
  <th class="num">Max Latency</th>
  <th class="num">Transfer/sec</th>
  <th class="bar-cell">Relative</th>
</tr></thead>
<tbody>
EOF

    awk -F',' -v ep="${endpoint}" -v maxr="${max_reqs}" '
    $1 == ep {
        pct = (maxr > 0) ? ($3 / maxr * 100) : 0
        printf "<tr>"
        printf "<td class=\"num\">%s</td>", $2
        printf "<td class=\"num\">%s</td>", $3
        printf "<td class=\"num\">%s</td>", $4
        printf "<td class=\"num\">%s</td>", $5
        printf "<td class=\"num\">%s</td>", $6
        printf "<td class=\"num\">%s</td>", $7
        printf "<td class=\"num\">%s</td>", $8
        printf "<td class=\"num\">%s</td>", $9
        printf "<td class=\"num\">%s</td>", $10
        printf "<td class=\"bar-cell\"><div class=\"bar-bg\"><div class=\"bar-fill\" style=\"width:%.0f%%\"></div></div></td>", pct
        printf "</tr>\n"
    }' "${RESULTS_FILE}" >> "${REPORT_FILE}"

    echo "</tbody></table></div>" >> "${REPORT_FILE}"
done

cat >> "${REPORT_FILE}" <<'FOOTER'
<footer>Ragnarok HTTP Server — wrk Benchmark Suite</footer>
</body></html>
FOOTER

rm -f "${RESULTS_FILE}"

echo "  Report written to ${REPORT_FILE}"
echo "========================================================="
echo ""
echo "  To extract the report from Docker:"
echo "    docker cp <container>:/app/reports/wrk_report.html ."
echo ""
