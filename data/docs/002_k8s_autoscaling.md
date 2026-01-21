# Kubernetes Autoscaling Fundamentals

Kubernetes provides several mechanisms to automatically scale workloads based on demand. Understanding these mechanisms is crucial for running efficient, cost-effective applications.

## Types of Autoscaling in Kubernetes

### 1. Horizontal Pod Autoscaler (HPA)

The HPA automatically scales the number of pod replicas based on observed metrics.

**Default Behavior:**
- Scales based on CPU utilization
- Can also use memory metrics
- Requires metrics-server to be installed

**Example HPA Configuration:**

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
```

### 2. Vertical Pod Autoscaler (VPA)

VPA automatically adjusts CPU and memory requests/limits for containers.

**Use Cases:**
- Applications with unpredictable resource needs
- Optimizing resource allocation
- Reducing over-provisioning

### 3. Cluster Autoscaler

Scales the number of nodes in a cluster based on pod scheduling demands.

**Triggers:**
- Pods pending due to insufficient resources
- Nodes underutilized for extended periods

## CPU-Based Scaling Considerations

CPU-based autoscaling works well for:
- Web servers handling HTTP requests
- Compute-intensive batch processing
- Applications where CPU correlates with load

CPU-based autoscaling fails for:
- I/O-bound workloads (database queries, API calls)
- Workloads waiting on external services
- LLM inference where GPU/memory is the bottleneck

## Metrics Server

The metrics server is a cluster-wide aggregator of resource usage data.

**Installation:**

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

**Verifying:**

```bash
kubectl top pods
kubectl top nodes
```

## Custom Metrics Autoscaling

For workloads where CPU isn't a good indicator, use custom metrics:

1. **Prometheus Adapter**: Exposes Prometheus metrics as Kubernetes custom metrics
2. **KEDA**: Event-driven autoscaling with multiple trigger types
3. **External Metrics**: Integration with cloud provider metrics

The key is choosing metrics that truly reflect application load and queue backlog.
