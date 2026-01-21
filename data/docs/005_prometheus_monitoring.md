# Prometheus for Kubernetes Monitoring

Prometheus is an open-source monitoring and alerting toolkit that has become the de facto standard for Kubernetes observability.

## Core Concepts

### Metrics

Prometheus uses a pull-based model where it scrapes metrics from targets at regular intervals.

**Metric Types:**

1. **Counter**: Monotonically increasing value (e.g., total requests)
2. **Gauge**: Value that can go up and down (e.g., queue depth)
3. **Histogram**: Distribution of values in buckets (e.g., latency)
4. **Summary**: Similar to histogram with quantiles

### Labels

Labels add dimensions to metrics:

```
http_requests_total{method="GET", status="200", path="/api"} 1234
```

## Installing Prometheus in Kubernetes

### Simple Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus
  template:
    spec:
      containers:
      - name: prometheus
        image: prom/prometheus:v2.47.0
        ports:
        - containerPort: 9090
        volumeMounts:
        - name: config
          mountPath: /etc/prometheus
      volumes:
      - name: config
        configMap:
          name: prometheus-config
```

### Scrape Configuration

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'kubernetes-pods'
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
```

## Querying with PromQL

### Basic Queries

```promql
# Current queue depth
agent_queue_depth{queue="default"}

# Rate of jobs processed (per second)
rate(agent_jobs_processed_total[5m])

# 95th percentile latency
histogram_quantile(0.95, rate(agent_job_duration_seconds_bucket[5m]))
```

### Aggregation

```promql
# Sum across all workers
sum(agent_queue_depth)

# Average by queue
avg by (queue) (agent_inflight)

# Max inflight across workers
max(agent_inflight{queue="default"})
```

## Metrics Endpoint Best Practices

When exposing metrics from your application:

1. **Use consistent naming**: `<app>_<metric>_<unit>`
2. **Add appropriate labels**: But not too many (cardinality explosion)
3. **Choose the right type**: Counter for counts, gauge for current values
4. **Document your metrics**: Include HELP and TYPE annotations

### Python Example

```python
from prometheus_client import Counter, Gauge, Histogram, start_http_server

# Define metrics
requests_total = Counter('app_requests_total', 'Total requests', ['method'])
queue_depth = Gauge('app_queue_depth', 'Queue depth', ['queue'])
latency = Histogram('app_latency_seconds', 'Request latency')

# Expose metrics
start_http_server(8000)
```

## Alerting

Prometheus Alertmanager handles alerts:

```yaml
groups:
- name: queue-alerts
  rules:
  - alert: HighQueueDepth
    expr: agent_queue_depth > 100
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Queue depth is high"
```

## Integration with KEDA

KEDA can use Prometheus as a metric source for autoscaling:

```yaml
triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus:9090
      query: sum(agent_queue_depth{queue="default"})
      threshold: "5"
```

This enables powerful, metric-driven autoscaling based on any Prometheus metric.
