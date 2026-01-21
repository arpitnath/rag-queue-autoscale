#!/usr/bin/env python3
"""
RAG Worker: Consumes jobs from Redis queue, runs RAG pipeline, stores results.
"""

import os
import sys
import json
import time
import signal
from datetime import datetime

import redis

from rag import get_rag_engine
from metrics import (
    start_metrics_server,
    increment_inflight,
    decrement_inflight,
    record_job_success,
    record_job_error,
    agent_job_duration,
)

# Configuration
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379")
QUEUE_NAME = os.getenv("QUEUE_NAME", "rag:jobs")
RESULT_PREFIX = os.getenv("RESULT_PREFIX", "rag:result:")
RESULT_TTL = int(os.getenv("RESULT_TTL", "3600"))  # 1 hour
BRPOP_TIMEOUT = int(os.getenv("BRPOP_TIMEOUT", "5"))  # seconds
WORKER_ID = os.getenv("WORKER_ID", os.getenv("HOSTNAME", "worker-local"))

# Shutdown flag
_shutdown = False


def signal_handler(signum, frame):
    """Handle shutdown signals gracefully."""
    global _shutdown
    print(f"\n[worker] Received signal {signum}, shutting down...")
    _shutdown = True


def get_redis_client():
    """Create Redis client."""
    return redis.from_url(REDIS_URL, decode_responses=True)


def process_job(rag_engine, job_data: dict) -> dict:
    """Process a single job through the RAG pipeline."""
    job_id = job_data.get("job_id", "unknown")
    question = job_data.get("question", "")

    if not question:
        raise ValueError("Job missing 'question' field")

    print(f"[worker] Processing job {job_id}: {question[:50]}...")

    # Run RAG pipeline
    result = rag_engine.answer(question)

    return {
        "job_id": job_id,
        "status": "completed",
        "question": question,
        "answer": result["answer"],
        "sources": result["sources"],
        "worker_id": WORKER_ID,
        "completed_at": datetime.utcnow().isoformat(),
    }


def store_result(client: redis.Redis, job_id: str, result: dict):
    """Store job result in Redis hash with TTL."""
    key = f"{RESULT_PREFIX}{job_id}"
    client.hset(
        key,
        mapping={
            "status": result["status"],
            "answer": result["answer"],
            "sources": json.dumps(result["sources"]),
            "worker_id": result["worker_id"],
            "completed_at": result["completed_at"],
        },
    )
    client.expire(key, RESULT_TTL)
    print(f"[worker] Result stored at {key}")


def store_error(client: redis.Redis, job_id: str, error: str):
    """Store error result in Redis."""
    key = f"{RESULT_PREFIX}{job_id}"
    client.hset(
        key,
        mapping={
            "status": "error",
            "error": str(error),
            "worker_id": WORKER_ID,
            "completed_at": datetime.utcnow().isoformat(),
        },
    )
    client.expire(key, RESULT_TTL)
    print(f"[worker] Error stored at {key}")


def worker_loop():
    """Main worker loop: BRPOP jobs from queue, process, store results."""
    global _shutdown

    print("=" * 60)
    print(f"RAG Worker Starting")
    print(f"  Worker ID: {WORKER_ID}")
    print(f"  Redis: {REDIS_URL}")
    print(f"  Queue: {QUEUE_NAME}")
    print("=" * 60)

    # Start metrics server
    start_metrics_server()

    # Initialize RAG engine (loads index + connects to Ollama)
    print("[worker] Initializing RAG engine...")
    rag_engine = get_rag_engine()
    rag_engine.initialize()
    print("[worker] RAG engine ready")

    # Connect to Redis
    client = get_redis_client()
    print(f"[worker] Connected to Redis, listening on queue: {QUEUE_NAME}")

    # Main loop
    while not _shutdown:
        try:
            # Blocking pop with timeout
            result = client.brpop(QUEUE_NAME, timeout=BRPOP_TIMEOUT)

            if result is None:
                # Timeout, no job available
                continue

            queue_name, job_json = result

            # Parse job
            try:
                job_data = json.loads(job_json)
            except json.JSONDecodeError as e:
                print(f"[worker] Invalid job JSON: {e}")
                record_job_error()
                continue

            job_id = job_data.get("job_id", "unknown")

            # Track metrics
            increment_inflight()
            start_time = time.time()

            try:
                # Process job
                result = process_job(rag_engine, job_data)

                # Store result
                store_result(client, job_id, result)

                # Record success
                record_job_success()

            except Exception as e:
                print(f"[worker] Job {job_id} failed: {e}")
                store_error(client, job_id, str(e))
                record_job_error()

            finally:
                # Record duration and decrement inflight
                elapsed = time.time() - start_time
                agent_job_duration.observe(elapsed)
                decrement_inflight()
                print(f"[worker] Job {job_id} completed in {elapsed:.2f}s")

        except redis.ConnectionError as e:
            print(f"[worker] Redis connection error: {e}")
            time.sleep(5)
        except Exception as e:
            print(f"[worker] Unexpected error: {e}")
            time.sleep(1)

    print("[worker] Shutdown complete")


def main():
    """Entry point."""
    # Register signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    try:
        worker_loop()
    except KeyboardInterrupt:
        print("\n[worker] Interrupted")
        sys.exit(0)


if __name__ == "__main__":
    main()
