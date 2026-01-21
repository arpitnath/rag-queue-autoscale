#!/bin/bash
# Visual demo: CPU-based HPA - Shows the "failure to scale" moment
# Focus: HPA sees low CPU, doesn't scale, queue grows

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

# Setup
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
MAX_PODS_SEEN=1
PEAK_QUEUE=0

while true; do
    QUEUE=$(kubectl exec -n $NAMESPACE deployment/redis -- redis-cli LLEN rag:jobs 2>/dev/null)
    [ -z "$QUEUE" ] && QUEUE=0
    [ "$QUEUE" -gt "$PEAK_QUEUE" ] && PEAK_QUEUE=$QUEUE
    PODS=$(kubectl get pods -n $NAMESPACE -l app=worker --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [ "$PODS" -gt "$MAX_PODS_SEEN" ] && MAX_PODS_SEEN=$PODS
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
    printf "${CYAN}CPU per Pod:${NC} ${BOLD}%-4s${NC} / 250m threshold (%-3s%% utilization)              \n" "${AVG_CPU}m" "$CPU_PERCENT"
    printf "    "
    draw_cpu $AVG_CPU
    printf "  ${RED}← CPU TOO LOW FOR HPA${NC}                  \n"
    echo ""
    echo ""

    # Show the HPA decision logic
    echo "${RED}┌─ HPA DECISION LOGIC ────────────────────────────────────────────┐${NC}"
    echo "${RED}│${NC}"
    printf "${RED}│${NC}   CPU observed:    ${BOLD}%3dm${NC} (%s%% of 250m threshold)\n" "$AVG_CPU" "$CPU_PERCENT"
    echo "${RED}│${NC}   Scale trigger:   CPU > 50% (250m)"
    printf "${RED}│${NC}   Current status:  ${BOLD}%3dm < 250m${NC}\n" "$AVG_CPU"
    echo "${RED}│${NC}"
    echo "${RED}│${NC}   ${YELLOW}Decision: \"CPU is fine. No scaling needed.\"${NC}"
    printf "${RED}│${NC}   ${DIM}Meanwhile: %3d jobs waiting in queue...${NC}\n" "$QUEUE"
    echo "${RED}│${NC}"
    echo "${RED}└──────────────────────────────────────────────────────────────────┘${NC}"

    [ "$QUEUE" = "0" ] && break
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
printf "${CYAN}Replicas:${NC} ${BOLD}%-2s${NC} / 20                         ${RED}← NEVER SCALED${NC}         \n" "$MAX_PODS_SEEN"
printf "    "
draw_pods $MAX_PODS_SEEN
printf "                                        \n"
echo ""
printf "${CYAN}CPU per Pod:${NC} ${BOLD}%-4s${NC} / 250m   ${DIM}stayed low throughout${NC}              \n" "${AVG_CPU}m"
printf "    "
draw_cpu $AVG_CPU
printf "                                        \n"
echo ""
echo ""

echo "${YELLOW}┌─ HPA RESULT ────────────────────────────────────────────────────┐${NC}"
echo "${YELLOW}│${NC}"
printf "${YELLOW}│${NC}   Jobs processed:     ${BOLD}%3d${NC}\n" "$JOBS"
printf "${YELLOW}│${NC}   Time to drain:      ${BOLD}%3ds${NC}\n" "$ELAPSED"
printf "${YELLOW}│${NC}   Max replicas:       ${BOLD}%3d${NC}  ${RED}(HPA never triggered)${NC}\n" "$MAX_PODS_SEEN"
printf "${YELLOW}│${NC}   Peak queue depth:   ${BOLD}%3d${NC}  ${DIM}(users waiting)${NC}\n" "$PEAK_QUEUE"
echo "${YELLOW}│${NC}"
echo "${YELLOW}│${NC}   ${RED}HPA saw low CPU and concluded: \"No scaling needed\"${NC}"
echo "${YELLOW}│${NC}"
echo "${YELLOW}└──────────────────────────────────────────────────────────────────┘${NC}"

kubectl delete hpa worker -n $NAMESPACE > /dev/null 2>&1

tput cnorm
