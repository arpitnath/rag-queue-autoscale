#!/bin/bash
# Visual demo: Queue-depth KEDA - Shows correct scaling behavior
# Focus: KEDA sees queue depth, scales to match demand

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
    printf "${GREEN}"
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

# Setup
echo ""
echo "${BOLD}${WHITE}╔═══════════════════════════════════════════════════════════════════╗${NC}"
echo "${BOLD}${WHITE}║              QUEUE-DEPTH AUTOSCALING (KEDA)                       ║${NC}"
echo "${BOLD}${WHITE}║              Target: 5 jobs per replica                           ║${NC}"
echo "${BOLD}${WHITE}╚═══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

kubectl delete hpa worker -n $NAMESPACE > /dev/null 2>&1
kubectl scale deployment worker -n $NAMESPACE --replicas=1 > /dev/null 2>&1
kubectl exec -n $NAMESPACE deployment/redis -- redis-cli DEL rag:jobs > /dev/null 2>&1
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
MAX_PODS=1
PEAK_QUEUE=0

while true; do
    QUEUE=$(kubectl exec -n $NAMESPACE deployment/redis -- redis-cli LLEN rag:jobs 2>/dev/null)
    [ -z "$QUEUE" ] && QUEUE=0
    [ "$QUEUE" -gt "$PEAK_QUEUE" ] && PEAK_QUEUE=$QUEUE
    PODS=$(kubectl get pods -n $NAMESPACE -l app=worker --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$PODS" -gt "$MAX_PODS" ] && MAX_PODS=$PODS
    TOTAL_CPU=$(kubectl top pods -n $NAMESPACE -l app=worker --no-headers 2>/dev/null | awk '{gsub(/m/,"",$2); sum+=$2} END {print sum+0}')
    [ "$PODS" -gt 0 ] && AVG_CPU=$((TOTAL_CPU / PODS)) || AVG_CPU=0
    ELAPSED=$(($(date +%s) - START))

    # Calculate desired replicas (KEDA formula)
    if [ "$QUEUE" -gt 0 ]; then
        DESIRED=$(( (QUEUE + 4) / 5 ))  # ceil(queue / 5)
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
    printf "${CYAN}Replicas:${NC} ${BOLD}%-2s${NC} / 20                         ${GREEN}← SCALING TO DEMAND${NC}    \n" "$PODS"
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

    # Show the KEDA decision logic
    echo "${GREEN}┌─ KEDA DECISION LOGIC ──────────────────────────────────────────┐${NC}"
    echo "${GREEN}│${NC}"
    printf "${GREEN}│${NC}   Queue depth:      ${BOLD}%3d${NC} jobs\n" "$QUEUE"
    echo "${GREEN}│${NC}   Threshold:        5 jobs per replica"
    printf "${GREEN}│${NC}   Calculation:      %3d / 5 = ${BOLD}%2d replicas needed${NC}\n" "$QUEUE" "$DESIRED"
    echo "${GREEN}│${NC}"
    printf "${GREEN}│${NC}   ${CYAN}Decision: \"Scale to %2d replicas to match demand\"${NC}\n" "$DESIRED"
    printf "${GREEN}│${NC}   ${DIM}Current replicas: %2d (scaling in progress...)${NC}\n" "$PODS"
    echo "${GREEN}│${NC}"
    echo "${GREEN}└──────────────────────────────────────────────────────────────────┘${NC}"

    if [ "$QUEUE" = "0" ]; then
        sleep 2
        QUEUE=$(kubectl exec -n $NAMESPACE deployment/redis -- redis-cli LLEN rag:jobs 2>/dev/null)
        [ "$QUEUE" = "0" ] && break
    fi
    sleep 3
done

# Final result
tput cup 7 0
printf "${CYAN}Time:${NC} ${BOLD}%-4s${NC} ${GREEN}COMPLETE${NC}                                            \n" "${ELAPSED}s"
echo ""
printf "${CYAN}Queue Depth:${NC} ${BOLD}%-4s${NC} / %-4s   ${GREEN}DRAINED${NC}                            \n" "0" "$JOBS"
printf "    "
draw_bar 0 $JOBS
printf "                                        \n"
echo ""
printf "${CYAN}Replicas:${NC} ${BOLD}%-2s${NC} / 20                         ${GREEN}← SCALED TO DEMAND${NC}     \n" "$MAX_PODS"
printf "    "
draw_pods $MAX_PODS
printf "                                        \n"
echo ""
printf "${CYAN}CPU per Pod:${NC} ${BOLD}%-4s${NC} / 250m   ${DIM}stayed low (I/O-bound)${NC}             \n" "${AVG_CPU}m"
printf "    "
draw_cpu $AVG_CPU
printf "                                        \n"
echo ""
echo ""

echo "${GREEN}┌─ KEDA RESULT ───────────────────────────────────────────────────┐${NC}"
echo "${GREEN}│${NC}"
printf "${GREEN}│${NC}   Jobs processed:     ${BOLD}%3d${NC}\n" "$JOBS"
printf "${GREEN}│${NC}   Time to drain:      ${BOLD}%3ds${NC}\n" "$ELAPSED"
printf "${GREEN}│${NC}   Max replicas:       ${BOLD}%3d${NC}  ${GREEN}(scaled to match demand)${NC}\n" "$MAX_PODS"
printf "${GREEN}│${NC}   Peak queue depth:   ${BOLD}%3d${NC}\n" "$PEAK_QUEUE"
echo "${GREEN}│${NC}"
printf "${GREEN}│${NC}   ${CYAN}KEDA saw queue depth and scaled: %d jobs -> %d replicas${NC}\n" "$PEAK_QUEUE" "$MAX_PODS"
echo "${GREEN}│${NC}"
echo "${GREEN}└──────────────────────────────────────────────────────────────────┘${NC}"

tput cnorm
