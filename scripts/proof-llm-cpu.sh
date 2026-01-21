#!/bin/bash
# Visual demo: CPU-based HPA vs Queue-depth KEDA
# Shows THE SCALING DECISION difference, not just speed
# For screen recording and GIF creation

NAMESPACE="rag-demo"
JOBS=200

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
DIM=$'\033[0;90m'
NC=$'\033[0m'
BOLD=$'\033[1m'

clear
tput civis
trap "tput cnorm; exit" EXIT INT TERM

draw_bar() {
    local current=$1
    local max=$2
    local width=50
    local filled=$((current * width / max))
    local empty=$((width - filled))

    printf "["
    printf "${RED}"
    for ((i=0; i<filled; i++)); do printf "█"; done
    printf "${DIM}"
    for ((i=0; i<empty; i++)); do printf "░"; done
    printf "${NC}]"
}

draw_pods() {
    local count=$1
    local max=20
    printf "${GREEN}"
    for ((i=0; i<count; i++)); do printf "●"; done
    printf "${DIM}"
    for ((i=count; i<max; i++)); do printf "○"; done
    printf "${NC}"
}

draw_cpu() {
    local cpu=$1
    local threshold=250
    local width=20
    local filled=$((cpu * width / threshold))
    [ $filled -gt $width ] && filled=$width

    if [ $cpu -lt 50 ]; then
        color=$GREEN
    elif [ $cpu -lt 200 ]; then
        color=$YELLOW
    else
        color=$RED
    fi

    printf "["
    printf "${color}"
    for ((i=0; i<filled; i++)); do printf "▮"; done
    printf "${DIM}"
    for ((i=filled; i<width; i++)); do printf "▯"; done
    printf "${NC}]"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 1: HPA (CPU-Based) - Shows the "failure to scale" moment
# ═══════════════════════════════════════════════════════════════════════════════

run_hpa_test() {
    clear
    echo ""
    echo "${BOLD}${WHITE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo "${BOLD}${WHITE}║              CPU-BASED AUTOSCALING (HPA)                          ║${NC}"
    echo "${BOLD}${WHITE}║              Target: 50% CPU (250m of 500m request)               ║${NC}"
    echo "${BOLD}${WHITE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    kubectl delete scaledobject worker-scaledobject -n $NAMESPACE > /dev/null 2>&1
    kubectl delete hpa worker -n $NAMESPACE > /dev/null 2>&1
    kubectl scale deployment worker -n $NAMESPACE --replicas=1 > /dev/null 2>&1
    kubectl exec -n $NAMESPACE deployment/redis -- redis-cli DEL rag:jobs > /dev/null 2>&1
    kubectl autoscale deployment worker -n $NAMESPACE --cpu-percent=50 --min=1 --max=20 > /dev/null 2>&1
    sleep 3

    echo "${DIM}Pushing $JOBS jobs to queue...${NC}"
    kubectl run -n $NAMESPACE loadgen-hpa --rm -i --restart=Never --image=redis:7-alpine -- sh -c "
    for i in \$(seq 1 $JOBS); do
      redis-cli -h redis LPUSH rag:jobs '{\"job_id\":\"hpa_\$i\",\"question\":\"What is Kubernetes?\"}' > /dev/null
    done
    " > /dev/null 2>&1
    echo ""

    START=$(date +%s)
    MAX_HPA_PODS=1
    HPA_PEAK_QUEUE=0

    while true; do
        QUEUE=$(kubectl exec -n $NAMESPACE deployment/redis -- redis-cli LLEN rag:jobs 2>/dev/null)
        [ -z "$QUEUE" ] && QUEUE=0
        [ "$QUEUE" -gt "$HPA_PEAK_QUEUE" ] && HPA_PEAK_QUEUE=$QUEUE
        PODS=$(kubectl get pods -n $NAMESPACE -l app=worker --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
        [ "$PODS" -gt "$MAX_HPA_PODS" ] && MAX_HPA_PODS=$PODS
        TOTAL_CPU=$(kubectl top pods -n $NAMESPACE -l app=worker --no-headers 2>/dev/null | awk '{gsub(/m/,"",$2); sum+=$2} END {print sum+0}')
        [ "$PODS" -gt 0 ] && AVG_CPU=$((TOTAL_CPU / PODS)) || AVG_CPU=0
        ELAPSED=$(($(date +%s) - START))
        CPU_PERCENT=$((AVG_CPU * 100 / 250))

        tput cup 7 0

        printf "${CYAN}Time:${NC} ${BOLD}%-4s${NC}                                                        \n" "${ELAPSED}s"
        echo ""
        printf "${CYAN}Queue Depth:${NC} ${BOLD}%-4s${NC} / %-4s                                          \n" "$QUEUE" "$JOBS"
        printf "    "
        draw_bar $QUEUE $JOBS
        printf "                                        \n"
        echo ""
        printf "${CYAN}Replicas:${NC} ${BOLD}%-2s${NC} / 20                         ${RED}← NOT SCALING${NC}          \n" "$PODS"
        printf "    "
        draw_pods $PODS
        printf "                                        \n"
        echo ""
        printf "${CYAN}CPU per Pod:${NC} ${BOLD}%-4s${NC} / 250m threshold (%-3s%%)                        \n" "${AVG_CPU}m" "$CPU_PERCENT"
        printf "    "
        draw_cpu $AVG_CPU
        printf "  ${RED}← TOO LOW${NC}                              \n"
        echo ""
        echo ""

        echo "${RED}┌─ HPA DECISION ──────────────────────────────────────────────────┐${NC}"
        echo "${RED}│${NC}"
        printf "${RED}│${NC}   CPU: ${BOLD}%3dm${NC} < 250m threshold\n" "$AVG_CPU"
        echo "${RED}│${NC}   ${YELLOW}\"CPU is fine. No scaling needed.\"${NC}"
        printf "${RED}│${NC}   ${DIM}Meanwhile: %3d jobs waiting...${NC}\n" "$QUEUE"
        echo "${RED}│${NC}"
        echo "${RED}└──────────────────────────────────────────────────────────────────┘${NC}"

        [ "$QUEUE" = "0" ] && break
        sleep 3
    done

    HPA_TIME=$ELAPSED
    HPA_AVG_CPU=$AVG_CPU
    kubectl delete hpa worker -n $NAMESPACE > /dev/null 2>&1
    kubectl exec -n $NAMESPACE deployment/redis -- redis-cli DEL rag:jobs > /dev/null 2>&1

    echo ""
    echo "${YELLOW}HPA finished in ${HPA_TIME}s with max ${MAX_HPA_PODS} replica(s)${NC}"
    echo ""
    echo "${DIM}Press Enter to see KEDA (queue-depth scaling)...${NC}"
    read
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 2: KEDA (Queue-Depth) - Shows correct scaling behavior
# ═══════════════════════════════════════════════════════════════════════════════

run_keda_test() {
    clear
    echo ""
    echo "${BOLD}${WHITE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo "${BOLD}${WHITE}║              QUEUE-DEPTH AUTOSCALING (KEDA)                       ║${NC}"
    echo "${BOLD}${WHITE}║              Target: 5 jobs per replica                           ║${NC}"
    echo "${BOLD}${WHITE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    kubectl scale deployment worker -n $NAMESPACE --replicas=1 > /dev/null 2>&1
    sleep 2
    kubectl apply -f deploy/k8s/50-keda-scaledobject.yaml > /dev/null 2>&1
    sleep 2

    echo "${DIM}Pushing $JOBS jobs to queue...${NC}"
    kubectl run -n $NAMESPACE loadgen-keda --rm -i --restart=Never --image=redis:7-alpine -- sh -c "
    for i in \$(seq 1 $JOBS); do
      redis-cli -h redis LPUSH rag:jobs '{\"job_id\":\"keda_\$i\",\"question\":\"What is Kubernetes?\"}' > /dev/null
    done
    " > /dev/null 2>&1
    echo ""

    START=$(date +%s)
    MAX_KEDA_PODS=1
    KEDA_PEAK_QUEUE=0

    while true; do
        QUEUE=$(kubectl exec -n $NAMESPACE deployment/redis -- redis-cli LLEN rag:jobs 2>/dev/null)
        [ -z "$QUEUE" ] && QUEUE=0
        [ "$QUEUE" -gt "$KEDA_PEAK_QUEUE" ] && KEDA_PEAK_QUEUE=$QUEUE
        PODS=$(kubectl get pods -n $NAMESPACE -l app=worker --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
        [ "$PODS" -gt "$MAX_KEDA_PODS" ] && MAX_KEDA_PODS=$PODS
        TOTAL_CPU=$(kubectl top pods -n $NAMESPACE -l app=worker --no-headers 2>/dev/null | awk '{gsub(/m/,"",$2); sum+=$2} END {print sum+0}')
        [ "$PODS" -gt 0 ] && AVG_CPU=$((TOTAL_CPU / PODS)) || AVG_CPU=0
        ELAPSED=$(($(date +%s) - START))

        # Calculate desired replicas
        if [ "$QUEUE" -gt 0 ]; then
            DESIRED=$(( (QUEUE + 4) / 5 ))
            [ "$DESIRED" -gt 20 ] && DESIRED=20
        else
            DESIRED=1
        fi

        tput cup 7 0

        printf "${CYAN}Time:${NC} ${BOLD}%-4s${NC}                                                        \n" "${ELAPSED}s"
        echo ""
        printf "${CYAN}Queue Depth:${NC} ${BOLD}%-4s${NC} / %-4s                                          \n" "$QUEUE" "$JOBS"
        printf "    "
        draw_bar $QUEUE $JOBS
        printf "                                        \n"
        echo ""
        printf "${CYAN}Replicas:${NC} ${BOLD}%-2s${NC} / 20                         ${GREEN}← SCALING${NC}              \n" "$PODS"
        printf "    "
        draw_pods $PODS
        printf "                                        \n"
        echo ""
        printf "${CYAN}CPU per Pod:${NC} ${BOLD}%-4s${NC} / 250m ${DIM}(still low - I/O bound)${NC}                \n" "${AVG_CPU}m"
        printf "    "
        draw_cpu $AVG_CPU
        printf "                                        \n"
        echo ""
        echo ""

        echo "${GREEN}┌─ KEDA DECISION ─────────────────────────────────────────────────┐${NC}"
        echo "${GREEN}│${NC}"
        printf "${GREEN}│${NC}   Queue: ${BOLD}%3d${NC} jobs / 5 = ${BOLD}%2d replicas needed${NC}\n" "$QUEUE" "$DESIRED"
        printf "${GREEN}│${NC}   ${CYAN}\"Scale to %2d replicas to match demand\"${NC}\n" "$DESIRED"
        printf "${GREEN}│${NC}   ${DIM}Current: %2d replicas${NC}\n" "$PODS"
        echo "${GREEN}│${NC}"
        echo "${GREEN}└──────────────────────────────────────────────────────────────────┘${NC}"

        if [ "$QUEUE" = "0" ]; then
            sleep 2
            QUEUE=$(kubectl exec -n $NAMESPACE deployment/redis -- redis-cli LLEN rag:jobs 2>/dev/null)
            [ "$QUEUE" = "0" ] && break
        fi
        sleep 3
    done

    KEDA_TIME=$ELAPSED
    KEDA_AVG_CPU=$AVG_CPU

    tput cup 7 0
    printf "${CYAN}Time:${NC} ${BOLD}%-4s${NC} ${GREEN}COMPLETE${NC}                                            \n" "${KEDA_TIME}s"
    echo ""
    printf "${CYAN}Queue Depth:${NC} ${BOLD}%-4s${NC} / %-4s   ${GREEN}DRAINED${NC}                            \n" "0" "$JOBS"
    printf "    "
    draw_bar 0 $JOBS
    printf "                                        \n"
    echo ""
    printf "${CYAN}Replicas:${NC} ${BOLD}%-2s${NC} / 20                         ${GREEN}← SCALED${NC}               \n" "$MAX_KEDA_PODS"
    printf "    "
    draw_pods $MAX_KEDA_PODS
    printf "                                        \n"
    echo ""
    printf "${CYAN}CPU per Pod:${NC} ${BOLD}%-4s${NC} / 250m   ${DIM}still low${NC}                          \n" "${AVG_CPU}m"
    printf "    "
    draw_cpu $AVG_CPU
    printf "                                        \n"
    echo ""
    echo ""

    echo "${GREEN}┌─ KEDA RESULT ───────────────────────────────────────────────────┐${NC}"
    echo "${GREEN}│${NC}"
    printf "${GREEN}│${NC}   Drained in ${BOLD}%3ds${NC} with ${BOLD}%2d${NC} replicas\n" "$KEDA_TIME" "$MAX_KEDA_PODS"
    printf "${GREEN}│${NC}   Queue depth drove scaling: %3d jobs -> %2d replicas\n" "$KEDA_PEAK_QUEUE" "$MAX_KEDA_PODS"
    echo "${GREEN}│${NC}"
    echo "${GREEN}└──────────────────────────────────────────────────────────────────┘${NC}"

    echo ""
    echo "${DIM}Press Enter to see comparison...${NC}"
    read
}

# ═══════════════════════════════════════════════════════════════════════════════
# COMPARISON - Focus on the scaling decision
# ═══════════════════════════════════════════════════════════════════════════════

show_comparison() {
    clear
    echo ""
    echo "${BOLD}${WHITE}┌──────────────────────────────────────────────────────────────────┐${NC}"
    echo "${BOLD}${WHITE}│                     THE SCALING DECISION                         │${NC}"
    echo "${BOLD}${WHITE}└──────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo ""
    echo "                      ${RED}HPA (CPU)${NC}           ${GREEN}KEDA (Queue)${NC}"
    echo "                      ─────────           ────────────"
    echo ""
    echo "  ${BOLD}Metric watched${NC}       CPU utilization     Queue depth"
    echo ""
    echo "  ${BOLD}With $JOBS jobs:${NC}"
    printf "    CPU observed      ${RED}%3dm${NC} (low)          ${GREEN}%3dm${NC} (low)\n" "$HPA_AVG_CPU" "$KEDA_AVG_CPU"
    printf "    Replicas          ${RED}%3d${NC}  ${RED}← STUCK${NC}        ${GREEN}%3d${NC}  ${GREEN}← SCALED${NC}\n" "$MAX_HPA_PODS" "$MAX_KEDA_PODS"
    echo ""
    echo "  ${BOLD}Scaling decision${NC}"
    echo "    HPA:              ${RED}\"CPU < 50%, no scale\"${NC}"
    printf "    KEDA:             ${GREEN}\"%d jobs / 5 = scale to %d\"${NC}\n" "$JOBS" "$MAX_KEDA_PODS"
    echo ""
    printf "  ${BOLD}Time to drain${NC}       ${RED}%4ds${NC}               ${GREEN}%4ds${NC}\n" "$HPA_TIME" "$KEDA_TIME"
    echo ""
    echo ""
    echo "${BOLD}${WHITE}┌─ THE POINT ─────────────────────────────────────────────────────┐${NC}"
    echo "${BOLD}${WHITE}│${NC}"
    echo "${BOLD}${WHITE}│${NC}  Both saw the SAME low CPU. Both workloads were I/O-bound."
    echo "${BOLD}${WHITE}│${NC}"
    printf "${BOLD}${WHITE}│${NC}  HPA concluded: ${RED}\"Everything is fine\"${NC} → stayed at ${RED}%d${NC} replica\n" "$MAX_HPA_PODS"
    printf "${BOLD}${WHITE}│${NC}  KEDA concluded: ${GREEN}\"%d jobs waiting\"${NC} → scaled to ${GREEN}%d${NC} replicas\n" "$JOBS" "$MAX_KEDA_PODS"
    echo "${BOLD}${WHITE}│${NC}"
    echo "${BOLD}${WHITE}│${NC}  ${CYAN}For I/O-bound workloads: CPU != demand. Queue depth = demand.${NC}"
    echo "${BOLD}${WHITE}│${NC}"
    echo "${BOLD}${WHITE}└──────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo ""
    echo "${DIM}Done. Press Ctrl+C to exit.${NC}"

    # Keep the comparison visible
    while true; do
        sleep 10
    done
}

# Run
run_hpa_test
run_keda_test
show_comparison

tput cnorm
