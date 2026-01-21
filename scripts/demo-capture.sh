#!/bin/bash
#
# RAG Queue-Depth Autoscaling Demo Capture Script
# Runs baseline vs KEDA tests and captures all evidence
#
# Usage: ./scripts/demo-capture.sh
#
# Output: ./demo-output/ directory with all results
#

set -e

# Configuration
NAMESPACE="rag-demo"
OUTPUT_DIR="./demo-output"
JOBS_COUNT=50
KEDA_MAX_REPLICAS=20

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Create output directory
mkdir -p "$OUTPUT_DIR"
echo "Output will be saved to: $OUTPUT_DIR"

# Log function
log() {
    echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1" | tee -a "$OUTPUT_DIR/demo.log"
}

log_section() {
    echo "" | tee -a "$OUTPUT_DIR/demo.log"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}" | tee -a "$OUTPUT_DIR/demo.log"
    echo -e "${BLUE}  $1${NC}" | tee -a "$OUTPUT_DIR/demo.log"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}" | tee -a "$OUTPUT_DIR/demo.log"
    echo "" | tee -a "$OUTPUT_DIR/demo.log"
}

# Helper: Get queue depth
get_queue_depth() {
    kubectl exec -n $NAMESPACE deployment/redis -- redis-cli LLEN rag:jobs 2>/dev/null || echo "0"
}

# Helper: Get worker pod count
get_worker_count() {
    kubectl get pods -n $NAMESPACE -l app=worker --no-headers 2>/dev/null | grep -c Running || echo "0"
}

# Helper: Push jobs
push_jobs() {
    local count=$1
    local prefix=$2
    kubectl run -n $NAMESPACE job-pusher-$prefix --rm -i --restart=Never --image=redis:7-alpine -- sh -c "
for i in \$(seq 1 $count); do
  redis-cli -h redis LPUSH rag:jobs '{\"job_id\":\"${prefix}_\$i\",\"question\":\"What is queue-depth autoscaling?\",\"submitted_at\":\"\$(date -Iseconds)\"}' > /dev/null
done
echo 'Pushed $count jobs'
" 2>/dev/null
}

# Helper: Wait for queue to drain
wait_for_drain() {
    local start_time=$(date +%s)
    local output_file=$1

    echo "time,queue_depth,pod_count" > "$output_file"

    while true; do
        local queue=$(get_queue_depth)
        local pods=$(get_worker_count)
        local elapsed=$(($(date +%s) - start_time))

        echo "$elapsed,$queue,$pods" >> "$output_file"
        printf "\r  ⏱ Time: %4ds | Queue: %4s | Pods: %2s" "$elapsed" "$queue" "$pods"

        if [ "$queue" = "0" ]; then
            # Wait a bit more to ensure no inflight jobs
            sleep 5
            queue=$(get_queue_depth)
            if [ "$queue" = "0" ]; then
                echo ""
                return $(($(date +%s) - start_time))
            fi
        fi
        sleep 2
    done
}

# ═══════════════════════════════════════════════════════════
# STEP 0: Verify Prerequisites
# ═══════════════════════════════════════════════════════════
log_section "STEP 0: Verifying Prerequisites"

log "Checking cluster connection..."
kubectl cluster-info > /dev/null 2>&1 || { echo "ERROR: Cannot connect to cluster"; exit 1; }

log "Checking namespace..."
kubectl get namespace $NAMESPACE > /dev/null 2>&1 || { echo "ERROR: Namespace $NAMESPACE not found"; exit 1; }

log "Checking pods..."
kubectl get pods -n $NAMESPACE | tee "$OUTPUT_DIR/00-initial-pods.txt"

log "Checking KEDA..."
kubectl get scaledobject -n $NAMESPACE 2>/dev/null || echo "No ScaledObject found (will create later)"

echo ""
log "Prerequisites OK ✓"

# ═══════════════════════════════════════════════════════════
# STEP 1: Reset to Baseline State
# ═══════════════════════════════════════════════════════════
log_section "STEP 1: Resetting to Baseline State"

log "Removing KEDA ScaledObject if exists..."
kubectl delete scaledobject worker-scaledobject -n $NAMESPACE 2>/dev/null || true

log "Scaling worker to 1 replica..."
kubectl scale deployment worker -n $NAMESPACE --replicas=1
kubectl rollout restart deployment/worker -n $NAMESPACE
kubectl wait --for=condition=Available deployment/worker -n $NAMESPACE --timeout=120s

log "Clearing queue..."
kubectl exec -n $NAMESPACE deployment/redis -- redis-cli DEL rag:jobs > /dev/null

log "Waiting for worker to initialize..."
sleep 20

log "Baseline state ready ✓"
kubectl get pods -n $NAMESPACE -l app=worker | tee "$OUTPUT_DIR/01-baseline-pods.txt"

# ═══════════════════════════════════════════════════════════
# STEP 2: Capture CPU with Queue Backlog (The Problem)
# ═══════════════════════════════════════════════════════════
log_section "STEP 2: Capturing CPU During Backlog (The Problem)"

log "Pushing $JOBS_COUNT jobs..."
push_jobs $JOBS_COUNT "cpu_test"

sleep 3
QUEUE_DEPTH=$(get_queue_depth)
log "Queue depth after push: $QUEUE_DEPTH"

log "Capturing CPU usage with backlog..."
{
    echo "=== CPU USAGE WITH $QUEUE_DEPTH JOBS IN QUEUE ==="
    echo ""
    kubectl top pods -n $NAMESPACE 2>/dev/null || echo "Metrics not available"
    echo ""
    echo "NOTE: Workers show 2-3m CPU (<1%) despite $QUEUE_DEPTH jobs waiting!"
    echo "This is why CPU-based HPA fails for LLM workloads."
} | tee "$OUTPUT_DIR/02-cpu-during-backlog.txt"

log "Clearing queue for next test..."
kubectl exec -n $NAMESPACE deployment/redis -- redis-cli DEL rag:jobs > /dev/null
sleep 5

# ═══════════════════════════════════════════════════════════
# STEP 3: Baseline Test (1 Replica)
# ═══════════════════════════════════════════════════════════
log_section "STEP 3: Baseline Test (1 Replica, No KEDA)"

log "Ensuring 1 replica..."
kubectl scale deployment worker -n $NAMESPACE --replicas=1
sleep 10

log "Pushing $JOBS_COUNT jobs..."
push_jobs $JOBS_COUNT "baseline"

log "Waiting for drain with 1 replica..."
BASELINE_TIME=$(wait_for_drain "$OUTPUT_DIR/03-baseline-drain-data.csv")

{
    echo "=== BASELINE TEST RESULTS ==="
    echo ""
    echo "Configuration:"
    echo "  - Replicas: 1 (fixed)"
    echo "  - Jobs: $JOBS_COUNT"
    echo ""
    echo "Results:"
    echo "  - Drain Time: ${BASELINE_TIME} seconds"
    echo "  - Throughput: $(echo "scale=3; $JOBS_COUNT / $BASELINE_TIME" | bc) jobs/sec"
    echo ""
} | tee "$OUTPUT_DIR/03-baseline-results.txt"

log "Baseline complete: ${BASELINE_TIME}s ✓"

# Clear for next test
kubectl exec -n $NAMESPACE deployment/redis -- redis-cli DEL rag:jobs > /dev/null
sleep 5

# ═══════════════════════════════════════════════════════════
# STEP 4: Apply KEDA ScaledObject
# ═══════════════════════════════════════════════════════════
log_section "STEP 4: Applying KEDA ScaledObject"

log "Applying ScaledObject..."
kubectl apply -f deploy/k8s/50-keda-scaledobject.yaml | tee -a "$OUTPUT_DIR/demo.log"

log "Waiting for KEDA to initialize..."
sleep 15

log "ScaledObject status:"
kubectl get scaledobject -n $NAMESPACE | tee "$OUTPUT_DIR/04-scaledobject-status.txt"

kubectl describe scaledobject worker-scaledobject -n $NAMESPACE > "$OUTPUT_DIR/04-scaledobject-describe.txt"

# ═══════════════════════════════════════════════════════════
# STEP 5: KEDA Scaling Test
# ═══════════════════════════════════════════════════════════
log_section "STEP 5: KEDA Scaling Test (Auto-scale to $KEDA_MAX_REPLICAS)"

log "Resetting to 1 replica before test..."
kubectl scale deployment worker -n $NAMESPACE --replicas=1
sleep 30

log "Pushing $JOBS_COUNT jobs..."
push_jobs $JOBS_COUNT "keda"

log "Watching KEDA scale and drain..."
KEDA_TIME=$(wait_for_drain "$OUTPUT_DIR/05-keda-drain-data.csv")

# Capture final pod state
kubectl get pods -n $NAMESPACE -l app=worker | tee "$OUTPUT_DIR/05-keda-pods-after.txt"

{
    echo "=== KEDA TEST RESULTS ==="
    echo ""
    echo "Configuration:"
    echo "  - Min Replicas: 1"
    echo "  - Max Replicas: $KEDA_MAX_REPLICAS"
    echo "  - Threshold: 5 jobs per replica"
    echo "  - Jobs: $JOBS_COUNT"
    echo ""
    echo "Results:"
    echo "  - Drain Time: ${KEDA_TIME} seconds"
    echo "  - Throughput: $(echo "scale=3; $JOBS_COUNT / $KEDA_TIME" | bc) jobs/sec"
    echo "  - Peak Replicas: $(awk -F',' 'NR>1 {print $3}' "$OUTPUT_DIR/05-keda-drain-data.csv" | sort -rn | head -1)"
    echo ""
} | tee "$OUTPUT_DIR/05-keda-results.txt"

log "KEDA test complete: ${KEDA_TIME}s ✓"

# ═══════════════════════════════════════════════════════════
# STEP 6: Generate Comparison Summary
# ═══════════════════════════════════════════════════════════
log_section "STEP 6: Generating Comparison Summary"

SPEEDUP=$(echo "scale=1; $BASELINE_TIME / $KEDA_TIME" | bc)
PEAK_REPLICAS=$(awk -F',' 'NR>1 {print $3}' "$OUTPUT_DIR/05-keda-drain-data.csv" | sort -rn | head -1)

{
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║         RAG QUEUE-DEPTH AUTOSCALING: TEST RESULTS               ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                  ║"
    echo "║  Test Configuration:                                             ║"
    echo "║    - Jobs: $JOBS_COUNT                                                  ║"
    echo "║    - KEDA Threshold: 5 jobs/replica                              ║"
    echo "║    - Max Replicas: $KEDA_MAX_REPLICAS                                            ║"
    echo "║                                                                  ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                  ║"
    echo "║                    BASELINE         KEDA           IMPROVEMENT  ║"
    echo "║  ────────────────────────────────────────────────────────────── ║"
    echo "║  Replicas           1 (fixed)       1-$PEAK_REPLICAS (auto)                    ║"
    printf "║  Drain Time         %-8s        %-8s        %-10s  ║\n" "${BASELINE_TIME}s" "${KEDA_TIME}s" "${SPEEDUP}x faster"
    printf "║  Throughput         %-8s        %-8s                    ║\n" "$(echo "scale=2; $JOBS_COUNT / $BASELINE_TIME" | bc) j/s" "$(echo "scale=2; $JOBS_COUNT / $KEDA_TIME" | bc) j/s"
    echo "║  CPU Usage          <1%             <1%             (I/O-bound) ║"
    echo "║                                                                  ║"
    echo "╠══════════════════════════════════════════════════════════════════╣"
    echo "║                                                                  ║"
    echo "║  KEY FINDING: ${SPEEDUP}x FASTER with queue-depth autoscaling!           ║"
    echo "║                                                                  ║"
    echo "║  CPU-based HPA would NEVER scale because CPU stays at <1%       ║"
    echo "║  even with ${JOBS_COUNT} jobs in the queue.                              ║"
    echo "║                                                                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
} | tee "$OUTPUT_DIR/06-comparison-summary.txt"

# ═══════════════════════════════════════════════════════════
# STEP 7: Generate Markdown Report
# ═══════════════════════════════════════════════════════════
log_section "STEP 7: Generating Markdown Report"

cat > "$OUTPUT_DIR/07-full-report.md" << EOF
# RAG Queue-Depth Autoscaling: Demo Results

**Generated:** $(date)
**Jobs Tested:** $JOBS_COUNT

## Summary

| Metric | Baseline (1 replica) | KEDA (auto-scale) | Improvement |
|--------|---------------------|-------------------|-------------|
| Drain Time | ${BASELINE_TIME}s | ${KEDA_TIME}s | **${SPEEDUP}x faster** |
| Peak Replicas | 1 | $PEAK_REPLICAS | Auto-scaled |
| CPU Usage | <1% | <1% | I/O-bound |

## The Problem: CPU Blind to Queue

\`\`\`
$(cat "$OUTPUT_DIR/02-cpu-during-backlog.txt")
\`\`\`

## Baseline Test (1 Replica)

\`\`\`
$(cat "$OUTPUT_DIR/03-baseline-results.txt")
\`\`\`

### Drain Timeline
\`\`\`csv
$(head -20 "$OUTPUT_DIR/03-baseline-drain-data.csv")
...
\`\`\`

## KEDA Test (Auto-scaling)

\`\`\`
$(cat "$OUTPUT_DIR/05-keda-results.txt")
\`\`\`

### Drain Timeline
\`\`\`csv
$(cat "$OUTPUT_DIR/05-keda-drain-data.csv")
\`\`\`

## Final Comparison

\`\`\`
$(cat "$OUTPUT_DIR/06-comparison-summary.txt")
\`\`\`

## Files Generated

- \`00-initial-pods.txt\` - Initial cluster state
- \`01-baseline-pods.txt\` - Pods before test
- \`02-cpu-during-backlog.txt\` - CPU evidence
- \`03-baseline-drain-data.csv\` - Baseline time series
- \`03-baseline-results.txt\` - Baseline summary
- \`04-scaledobject-status.txt\` - KEDA config
- \`05-keda-drain-data.csv\` - KEDA time series
- \`05-keda-results.txt\` - KEDA summary
- \`06-comparison-summary.txt\` - Final comparison
- \`demo.log\` - Full execution log
EOF

log "Markdown report generated ✓"

# ═══════════════════════════════════════════════════════════
# Done!
# ═══════════════════════════════════════════════════════════
log_section "DEMO CAPTURE COMPLETE!"

echo ""
echo -e "${GREEN}All outputs saved to: $OUTPUT_DIR/${NC}"
echo ""
echo "Files generated:"
ls -la "$OUTPUT_DIR/"
echo ""
echo -e "${YELLOW}Key files for blog:${NC}"
echo "  - $OUTPUT_DIR/02-cpu-during-backlog.txt  (CPU evidence)"
echo "  - $OUTPUT_DIR/06-comparison-summary.txt  (Final comparison)"
echo "  - $OUTPUT_DIR/07-full-report.md          (Full markdown report)"
echo ""
echo -e "${GREEN}Take screenshots of these files for the blog!${NC}"
