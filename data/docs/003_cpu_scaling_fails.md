# Why CPU Autoscaling Fails for LLM Workloads

When running LLM inference workloads at scale, many teams discover that traditional CPU-based autoscaling doesn't work as expected. This document explains why and offers better alternatives.

## The Problem

Consider a typical RAG (Retrieval-Augmented Generation) worker:

1. Receives a question from a queue
2. Retrieves relevant documents (fast, ~100ms)
3. Sends context + question to LLM (slow, 5-60 seconds)
4. Returns the answer

During step 3, the worker is mostly **waiting**. The CPU is idle while:
- Network I/O sends the request to Ollama/OpenAI
- The LLM model generates tokens
- Results stream back

## CPU Utilization vs Actual Load

**Scenario:** Queue has 100 pending jobs, 1 worker processing

| Metric | Value |
|--------|-------|
| Queue Depth | 100 |
| CPU Usage | 5-15% |
| Worker Status | Busy (waiting on LLM) |
| HPA Action | None (CPU below threshold) |

The HPA sees low CPU and decides no scaling is needed, while users wait minutes for their requests!

## Why This Happens

LLM inference is fundamentally different from traditional compute workloads:

1. **I/O Bound**: Most time is spent waiting for model responses
2. **Variable Duration**: Simple questions take 2s, complex ones take 60s
3. **Memory Intensive**: Model loading uses RAM/VRAM, not CPU
4. **Sequential Processing**: Workers often process one request at a time

## The Real Indicator: Queue Depth

Queue depth (number of pending jobs) is a much better indicator because:

- It directly measures **waiting work**
- Increases when load exceeds capacity
- Decreases when workers catch up
- Reflects actual user experience

## Queue-Depth Autoscaling Formula

A simple approach:

```
desired_replicas = ceil(queue_depth / jobs_per_worker_per_minute)
```

With KEDA, this becomes automatic:

```yaml
triggers:
  - type: prometheus
    metadata:
      query: sum(agent_queue_depth{queue="default"})
      threshold: "5"  # 5 jobs per replica
```

## Other Failing Scenarios

CPU-based scaling also fails for:

- **Database-bound workers**: Waiting on queries
- **API integrations**: Waiting on external services
- **File processing**: Waiting on I/O
- **GPU workloads**: GPU is busy, CPU is idle

## Recommendations

1. **Monitor queue depth** as the primary scaling metric
2. **Set appropriate thresholds** based on job duration
3. **Use KEDA** for event-driven autoscaling
4. **Add cooldown periods** to prevent thrashing
5. **Monitor latency** as the user-facing metric

The goal is to scale based on **work waiting to be done**, not on CPU utilization of workers doing the work.
