# Redis as a Job Queue

Redis is often used as a lightweight job queue due to its simplicity, performance, and built-in data structures.

## Why Redis for Queues?

1. **Simple**: No complex setup or dependencies
2. **Fast**: In-memory operations, microsecond latency
3. **Reliable**: Persistence options, replication
4. **Built-in structures**: Lists are natural queues

## List-Based Queue Pattern

Redis lists support LPUSH (add to left) and RPOP (remove from right), creating a FIFO queue:

```
LPUSH queue job1 job2 job3    # Producer adds jobs
RPOP queue                     # Consumer removes job3
BRPOP queue 0                  # Blocking pop (waits for jobs)
```

### Producer (Python)

```python
import redis
import json

r = redis.Redis()

job = {
    "job_id": "job_123",
    "question": "What is RAG?"
}

r.lpush("queue:jobs", json.dumps(job))
```

### Consumer (Python)

```python
import redis
import json

r = redis.Redis()

while True:
    # Blocking pop with timeout
    result = r.brpop("queue:jobs", timeout=5)
    if result:
        queue, job_json = result
        job = json.loads(job_json)
        process(job)
```

## Monitoring Queue Depth

Use LLEN to get the number of items in a queue:

```python
depth = r.llen("queue:jobs")
print(f"Queue depth: {depth}")
```

This is perfect for Prometheus metrics:

```python
from prometheus_client import Gauge

queue_depth = Gauge('queue_depth', 'Jobs in queue', ['queue'])

def update_queue_depth():
    depth = r.llen("queue:jobs")
    queue_depth.labels(queue="jobs").set(depth)
```

## Storing Results

Use Redis hashes for structured results:

```python
# Store result
r.hset(f"result:{job_id}", mapping={
    "status": "completed",
    "answer": "RAG is...",
    "completed_at": "2024-01-15T10:30:00Z"
})

# Set TTL (1 hour)
r.expire(f"result:{job_id}", 3600)

# Retrieve result
result = r.hgetall(f"result:{job_id}")
```

## Redis in Kubernetes

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
```

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
  - port: 6379
```

## Best Practices

1. **Use blocking ops**: BRPOP prevents busy-waiting
2. **Set timeouts**: Don't block forever
3. **Handle disconnects**: Reconnect on errors
4. **Monitor depth**: Track queue health
5. **Set TTLs on results**: Prevent memory bloat

## Comparison to Other Queues

| Feature | Redis | RabbitMQ | Kafka |
|---------|-------|----------|-------|
| Complexity | Low | Medium | High |
| Persistence | Optional | Yes | Yes |
| Ordering | FIFO | FIFO | Partition-ordered |
| Scale | Single node | Cluster | Distributed |
| Best for | Simple queues | Complex routing | Event streaming |

Redis is ideal for simple job queues in small to medium deployments.
