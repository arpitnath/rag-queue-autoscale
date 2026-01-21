# RAG Queue-Depth Autoscaling Demo

> CPU autoscaling fails for LLM inference. Queue-depth scaling works. **27 min → 43 sec (38x faster).**

Companion repo for: **[The Autoscaler Was Working Perfectly. That's Why Our AI Agents Couldn't Scale.](#)**

---

## The Problem

```
NAME                      CPU(cores)   MEMORY(bytes)
worker-775b9c855d-98qmj   3m           371Mi
worker-775b9c855d-mnq6c   3m           365Mi
```

**3 millicores (<1% CPU) with 100+ jobs queued.** HPA never scales.

## The Fix

```yaml
triggers:
- type: prometheus
  metadata:
    query: sum(agent_queue_depth{queue="default"})
    threshold: "5"
```

`replicas = ceil(queue_depth / threshold)`

---

## Results

| Metric | CPU-Based HPA | Queue-Depth (KEDA) |
|--------|---------------|-------------------|
| Drain time | 27m 36s | **43s** |
| Replicas | 1 | 1 → 20 |
| Improvement | — | **38x** |

---

## Quick Start

### Local (Docker Compose)

```bash
# Prerequisites: Ollama running with mistral model
ollama pull mistral && ollama serve

# Build and run
make build && make build-index && make run

# Push load
pip install redis
make push-jobs N=100
make metrics
```

### Kubernetes (kind + KEDA)

```bash
kind create cluster --name rag-demo
kubectl apply -f https://github.com/kedacore/keda/releases/download/v2.12.0/keda-2.12.0.yaml
make k8s-deploy
kubectl apply -f deploy/k8s/50-keda-scaledobject.yaml

# Run the proof
./scripts/proof-llm-cpu.sh
```

---

## Architecture

```
Load Generator → Redis Queue → Worker(s) → Ollama/LLM
                                   ↓
                            Prometheus → KEDA → Scale 1-20
```

## Stack

- **Queue**: Redis (LPUSH/BRPOP)
- **Vector Store**: FAISS + sentence-transformers
- **LLM**: Mistral 7B via Ollama
- **Autoscaling**: KEDA + Prometheus

## Metrics

| Metric | Description |
|--------|-------------|
| `agent_queue_depth` | Jobs waiting |
| `agent_inflight` | Jobs processing |
| `agent_job_duration_seconds` | End-to-end latency |
| `agent_llm_latency_seconds` | LLM inference time |

---

## Structure

```
app/           # worker.py, rag.py, metrics.py, indexer.py
data/docs/     # Sample documents for RAG
deploy/k8s/    # Kubernetes manifests
loadgen/       # push_jobs.py
scripts/       # proof-llm-cpu.sh
```

---

## License

MIT
