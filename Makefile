.PHONY: help build build-index run stop logs push-jobs get-result metrics clean

# Default target
help:
	@echo "RAG Queue Autoscale - Available Commands"
	@echo "=========================================="
	@echo ""
	@echo "Local Development (docker-compose):"
	@echo "  make build        - Build Docker image"
	@echo "  make build-index  - Build FAISS index from documents"
	@echo "  make run          - Start Redis and Worker"
	@echo "  make stop         - Stop all services"
	@echo "  make logs         - View worker logs"
	@echo "  make metrics      - Fetch Prometheus metrics"
	@echo ""
	@echo "Load Testing:"
	@echo "  make push-jobs N=50       - Push N jobs to queue"
	@echo "  make get-result JOB_ID=x  - Get result for job ID"
	@echo "  make queue-depth          - Check current queue depth"
	@echo ""
	@echo "Kubernetes:"
	@echo "  make k8s-deploy   - Deploy to Kubernetes"
	@echo "  make k8s-delete   - Delete from Kubernetes"
	@echo "  make k8s-logs     - View worker logs"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean        - Remove containers and volumes"

# Default values
N ?= 50
JOB_ID ?= job_1
REDIS_URL ?= redis://localhost:6379

# =============================================================================
# Local Development
# =============================================================================

# Build Docker image
build:
	docker compose build

# Build FAISS index (run before starting worker)
build-index:
	@echo "Building FAISS index from documents..."
	docker compose run --rm worker python indexer.py

# Start services
run:
	docker compose up -d
	@echo ""
	@echo "Services started!"
	@echo "  Redis:   localhost:6379"
	@echo "  Metrics: http://localhost:8000/metrics"
	@echo ""
	@echo "Check logs: make logs"

# Stop services
stop:
	docker compose down

# View logs
logs:
	docker compose logs -f worker

# Fetch metrics
metrics:
	@curl -s http://localhost:8000/metrics | grep -E "^agent_"

# =============================================================================
# Load Testing
# =============================================================================

# Push jobs to queue
push-jobs:
	@echo "Pushing $(N) jobs to queue..."
	python loadgen/push_jobs.py -n $(N) --redis-url $(REDIS_URL)

# Get result for a job
get-result:
	@echo "Getting result for $(JOB_ID)..."
	@redis-cli -u $(REDIS_URL) HGETALL "rag:result:$(JOB_ID)"

# Check queue depth
queue-depth:
	@echo -n "Queue depth: "
	@redis-cli -u $(REDIS_URL) LLEN "rag:jobs"

# =============================================================================
# Kubernetes
# =============================================================================

# Deploy to Kubernetes
k8s-deploy:
	@echo "Deploying to Kubernetes..."
	kubectl apply -f deploy/k8s/00-namespace.yaml
	kubectl apply -f deploy/k8s/10-redis.yaml
	kubectl apply -f deploy/k8s/15-indexer-job.yaml
	kubectl apply -f deploy/k8s/20-worker.yaml
	kubectl apply -f deploy/k8s/30-worker-service.yaml
	kubectl apply -f deploy/k8s/40-prometheus.yaml
	@echo ""
	@echo "Waiting for Redis to be ready..."
	kubectl wait --for=condition=ready pod -l app=redis -n rag-demo --timeout=120s
	@echo ""
	@echo "Waiting for indexer job to complete..."
	kubectl wait --for=condition=complete job/indexer -n rag-demo --timeout=300s
	@echo ""
	@echo "Deployment complete!"
	@echo "Apply KEDA ScaledObject after installing KEDA:"
	@echo "  kubectl apply -f deploy/k8s/50-keda-scaledobject.yaml"

# Delete from Kubernetes
k8s-delete:
	kubectl delete -f deploy/k8s/ --ignore-not-found

# View worker logs in Kubernetes
k8s-logs:
	kubectl logs -f -l app=worker -n rag-demo

# Port-forward Prometheus
k8s-prometheus:
	@echo "Prometheus available at http://localhost:9090"
	kubectl port-forward svc/prometheus 9090:9090 -n rag-demo

# Watch pods
k8s-watch:
	kubectl get pods -n rag-demo -w

# =============================================================================
# Cleanup
# =============================================================================

# Clean up everything
clean:
	docker compose down -v
	rm -rf data/faiss_index
	@echo "Cleaned up containers, volumes, and index"
