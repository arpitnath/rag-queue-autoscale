# KEDA: Kubernetes Event-Driven Autoscaling

KEDA (Kubernetes Event-Driven Autoscaling) is a powerful autoscaling solution that extends Kubernetes HPA with event-driven capabilities.

## What is KEDA?

KEDA is a single-purpose, lightweight component that:

- Extends Kubernetes with event-driven autoscaling
- Scales deployments from 0 to N based on events
- Supports 60+ built-in scalers
- Works alongside native HPA

## Architecture

KEDA consists of three main components:

1. **Metrics Server**: Exposes external metrics to Kubernetes
2. **Controller**: Watches ScaledObjects and manages scaling
3. **Admission Webhooks**: Validates configurations

## Installation

Install KEDA using kubectl:

```bash
# Install KEDA v2.12
kubectl apply -f https://github.com/kedacore/keda/releases/download/v2.12.0/keda-2.12.0.yaml

# Verify installation
kubectl get pods -n keda
```

Or using Helm:

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

## ScaledObject Configuration

The ScaledObject is KEDA's main custom resource:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker-scaledobject
spec:
  scaleTargetRef:
    name: worker-deployment
  minReplicaCount: 1
  maxReplicaCount: 100
  pollingInterval: 15
  cooldownPeriod: 300
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus:9090
        metricName: queue_depth
        query: sum(agent_queue_depth)
        threshold: "10"
```

## Key Parameters

| Parameter | Description | Recommendation |
|-----------|-------------|----------------|
| minReplicaCount | Minimum replicas | Set to 1 for always-ready workers |
| maxReplicaCount | Maximum replicas | Set based on cluster capacity |
| pollingInterval | How often to check metrics (seconds) | 10-30 for responsive scaling |
| cooldownPeriod | Wait time before scaling down (seconds) | 60-300 to prevent thrashing |

## Popular Scalers

### Prometheus Scaler

```yaml
triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus:9090
      query: sum(rate(http_requests_total[2m]))
      threshold: "100"
```

### Redis Scaler

```yaml
triggers:
  - type: redis
    metadata:
      address: redis:6379
      listName: myqueue
      listLength: "5"
```

### RabbitMQ Scaler

```yaml
triggers:
  - type: rabbitmq
    metadata:
      host: amqp://rabbitmq:5672
      queueName: myqueue
      queueLength: "10"
```

## Advanced Features

### Scale to Zero

KEDA can scale deployments to zero replicas when idle:

```yaml
spec:
  minReplicaCount: 0
  idleReplicaCount: 0
```

### Multiple Triggers

Combine multiple triggers with different thresholds:

```yaml
triggers:
  - type: prometheus
    metadata:
      query: queue_depth
      threshold: "10"
  - type: cpu
    metadata:
      type: Utilization
      value: "50"
```

## KEDA vs Native HPA

| Feature | Native HPA | KEDA |
|---------|-----------|------|
| CPU/Memory scaling | ✅ | ✅ |
| Custom metrics | Limited | 60+ scalers |
| Scale to zero | ❌ | ✅ |
| Event-driven | ❌ | ✅ |
| External metrics | Complex setup | Built-in |

KEDA is the recommended solution for queue-based and event-driven workloads.
