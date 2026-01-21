"""
Prometheus metrics for RAG worker.
Exposes queue depth, inflight jobs, processed counts, and latency histograms.
"""

import os
import threading
from prometheus_client import (
    Gauge,
    Counter,
    Histogram,
    start_http_server,
    REGISTRY,
)
import redis

# Configuration
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
QUEUE_NAME = os.getenv("QUEUE_NAME", "rag:jobs")

# Redis client for queue depth
_redis_client = None


def get_redis_client():
    """Lazy initialization of Redis client."""
    global _redis_client
    if _redis_client is None:
        _redis_client = redis.from_url(REDIS_URL, decode_responses=True)
    return _redis_client


# -----------------------------------------------------------------------------
# Metrics Definitions
# -----------------------------------------------------------------------------

# Queue depth - derived from Redis LLEN
agent_queue_depth = Gauge(
    "agent_queue_depth",
    "Number of jobs waiting in the queue",
    ["queue"],
)

# Inflight jobs - currently being processed
agent_inflight = Gauge(
    "agent_inflight",
    "Number of jobs currently being processed",
    ["queue"],
)

# Jobs processed counter
agent_jobs_processed = Counter(
    "agent_jobs_processed_total",
    "Total number of jobs processed",
    ["status"],  # ok or err
)

# Job duration histogram
agent_job_duration = Histogram(
    "agent_job_duration_seconds",
    "Time taken to process a job end-to-end",
    buckets=[0.5, 1, 2, 5, 10, 30, 60, 120, 300],
)

# Retrieval latency histogram
agent_retrieval_latency = Histogram(
    "agent_retrieval_latency_seconds",
    "Time taken for vector retrieval",
    buckets=[0.01, 0.05, 0.1, 0.25, 0.5, 1, 2],
)

# LLM latency histogram
agent_llm_latency = Histogram(
    "agent_llm_latency_seconds",
    "Time taken for LLM generation",
    buckets=[0.5, 1, 2, 5, 10, 30, 60, 120],
)


# -----------------------------------------------------------------------------
# Queue Depth Collector
# -----------------------------------------------------------------------------

class QueueDepthCollector:
    """Background thread that updates queue depth metric."""

    def __init__(self, interval: float = 5.0):
        self.interval = interval
        self._stop_event = threading.Event()
        self._thread = None

    def _collect_loop(self):
        while not self._stop_event.wait(self.interval):
            try:
                client = get_redis_client()
                depth = client.llen(QUEUE_NAME)
                agent_queue_depth.labels(queue="default").set(depth)
            except Exception as e:
                print(f"[metrics] Failed to get queue depth: {e}")

    def start(self):
        if self._thread is None:
            self._thread = threading.Thread(target=self._collect_loop, daemon=True)
            self._thread.start()
            print(f"[metrics] Queue depth collector started (interval={self.interval}s)")

    def stop(self):
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=2)


# Global collector instance
_queue_collector = QueueDepthCollector()


# -----------------------------------------------------------------------------
# Metrics Server
# -----------------------------------------------------------------------------

def start_metrics_server(port: int = None):
    """Start the Prometheus metrics HTTP server."""
    port = port or METRICS_PORT
    start_http_server(port)
    print(f"[metrics] Prometheus metrics server started on port {port}")
    
    # Start queue depth collection
    _queue_collector.start()


def increment_inflight():
    """Increment the inflight gauge."""
    agent_inflight.labels(queue="default").inc()


def decrement_inflight():
    """Decrement the inflight gauge."""
    agent_inflight.labels(queue="default").dec()


def record_job_success():
    """Record a successful job."""
    agent_jobs_processed.labels(status="ok").inc()


def record_job_error():
    """Record a failed job."""
    agent_jobs_processed.labels(status="err").inc()
