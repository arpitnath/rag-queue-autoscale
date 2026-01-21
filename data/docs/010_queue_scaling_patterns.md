# Queue-Depth Autoscaling Design Patterns

This document covers design patterns for implementing queue-based autoscaling in Kubernetes.

## The Queue-Depth Pattern

Instead of scaling on CPU/memory, scale based on:
- Number of pending jobs in queue
- Jobs per worker threshold
- Target processing latency

### Basic Formula

```
desired_replicas = ceil(queue_depth / jobs_per_replica_threshold)
```

Example: If queue has 50 jobs and threshold is 5:
```
desired_replicas = ceil(50 / 5) = 10 replicas
```

## Implementation with KEDA

### Simple Queue-Depth Scaling

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-scaler
spec:
  scaleTargetRef:
    name: worker
  minReplicaCount: 1
  maxReplicaCount: 20
  triggers:
    - type: prometheus
      metadata:
        query: sum(agent_queue_depth)
        threshold: "5"
```

### With Stabilization

```yaml
spec:
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleDown:
          stabilizationWindowSeconds: 300
          policies:
          - type: Percent
            value: 50
            periodSeconds: 60
```

## Metrics Design

### Required Metrics

1. **queue_depth**: Jobs waiting to be processed
2. **inflight**: Jobs currently being processed  
3. **processed_total**: Completed jobs (counter)
4. **job_duration**: Processing time (histogram)

### Derived Metrics

```promql
# Processing rate (jobs/second)
rate(agent_jobs_processed_total[5m])

# Average job duration
rate(agent_job_duration_seconds_sum[5m]) / rate(agent_job_duration_seconds_count[5m])

# Estimated drain time
agent_queue_depth / rate(agent_jobs_processed_total[5m])
```

## Threshold Selection

### Conservative (High Throughput)

```yaml
threshold: "3"  # Low threshold = more replicas
cooldownPeriod: 30
```

### Cost-Optimized

```yaml
threshold: "10"  # Higher threshold = fewer replicas
cooldownPeriod: 300
```

### Latency-Sensitive

```yaml
threshold: "1"  # Aggressive scaling
minReplicaCount: 2  # Always ready
cooldownPeriod: 60
```

## Handling Spikes

### Burst Pattern

For sudden traffic spikes:

```yaml
spec:
  pollingInterval: 5   # Fast detection
  cooldownPeriod: 120  # Slow scale-down
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:
          policies:
          - type: Pods
            value: 10
            periodSeconds: 15
```

### Predictable Load

For known patterns (e.g., business hours):

```yaml
triggers:
  - type: cron
    metadata:
      timezone: America/New_York
      start: 0 8 * * 1-5   # 8 AM weekdays
      end: 0 18 * * 1-5    # 6 PM weekdays
      desiredReplicas: "5"
```

## Anti-Patterns to Avoid

### 1. Scaling on CPU for I/O-Bound Work

❌ **Wrong:**
```yaml
metrics:
- type: Resource
  resource:
    name: cpu
    target:
      averageUtilization: 50
```

✅ **Right:**
```yaml
triggers:
- type: prometheus
  metadata:
    query: sum(agent_queue_depth)
    threshold: "5"
```

### 2. Too Aggressive Scale-Down

❌ **Wrong:**
```yaml
cooldownPeriod: 10
```

✅ **Right:**
```yaml
cooldownPeriod: 60  # At minimum
```

### 3. Ignoring Cold Start

Workers need time to:
- Pull images
- Initialize connections
- Load models/indexes

Account for this in threshold settings.

## Monitoring Scaling Behavior

### Key Queries

```promql
# Current replicas
kube_deployment_spec_replicas{deployment="worker"}

# Queue depth over time
agent_queue_depth{queue="default"}

# Scaling events
kube_horizontalpodautoscaler_status_current_replicas
```

### Alerting

```yaml
- alert: HighQueueLatency
  expr: agent_queue_depth > 100 and rate(agent_jobs_processed_total[5m]) < 10
  for: 5m
  annotations:
    summary: "Queue backing up, scaling may be insufficient"
```
