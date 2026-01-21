#!/bin/bash
# Complete test script for RAG Queue Autoscale
# Run this from the rag-queue-autoscale directory

set -e  # Exit on error

echo "=============================================="
echo "RAG Queue Autoscale - Complete Test Suite"
echo "=============================================="
echo ""

# Step 1: Build Docker image (with cache clear for requirements)
echo "=== Step 1: Building Docker image (no cache) ==="
docker compose build --no-cache

# Step 2: Build FAISS index
echo ""
echo "=== Step 2: Building FAISS index ==="
docker compose run --rm worker python indexer.py

# Step 3: Start services
echo ""
echo "=== Step 3: Starting services ==="
docker compose up -d

# Step 4: Wait for worker to initialize
echo ""
echo "=== Step 4: Waiting for worker to initialize (15s) ==="
sleep 15

# Step 5: Check worker logs
echo ""
echo "=== Step 5: Worker logs ==="
docker compose logs worker | tail -30

# Step 6: Install redis Python package if needed
echo ""
echo "=== Step 6: Checking redis package ==="
pip install redis -q

# Step 7: Push 5 test jobs
echo ""
echo "=== Step 7: Pushing 5 test jobs ==="
python loadgen/push_jobs.py -n 5

# Step 8: Wait for processing
echo ""
echo "=== Step 8: Waiting 60s for jobs to process ==="
sleep 60

# Step 9: Check metrics
echo ""
echo "=== Step 9: Checking metrics ==="
curl -s http://localhost:8000/metrics | grep -E "^agent_" || echo "Metrics endpoint not available"

# Step 10: Check results in Redis
echo ""
echo "=== Step 10: Checking results in Redis ==="
docker exec rag-redis redis-cli KEYS "rag:result:*"

# Step 11: Get a sample result
echo ""
echo "=== Step 11: Sample result content ==="
FIRST_KEY=$(docker exec rag-redis redis-cli KEYS "rag:result:*" | head -1 | tr -d '\r')
if [ -n "$FIRST_KEY" ]; then
    docker exec rag-redis redis-cli HGETALL "$FIRST_KEY"
else
    echo "No results found yet"
fi

# Step 12: Show worker logs again
echo ""
echo "=== Step 12: Latest worker logs ==="
docker compose logs worker --tail=20

echo ""
echo "=============================================="
echo "Test Complete!"
echo "=============================================="
echo ""
echo "To monitor ongoing:"
echo "  - Logs: docker compose logs -f worker"
echo "  - Metrics: curl http://localhost:8000/metrics | grep agent_"
echo "  - Queue depth: docker exec rag-redis redis-cli LLEN rag:jobs"
echo ""
echo "To stop: docker compose down"
