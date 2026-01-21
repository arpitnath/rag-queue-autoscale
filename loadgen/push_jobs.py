#!/usr/bin/env python3
"""
Load Generator: Pushes RAG jobs to Redis queue for testing autoscaling.
"""

import argparse
import json
import random
import sys
import time
import uuid
from pathlib import Path

import redis


def load_questions(questions_file: str) -> list:
    """Load questions from file."""
    path = Path(questions_file)
    if not path.exists():
        print(f"Questions file not found: {questions_file}")
        sys.exit(1)

    questions = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                questions.append(line)

    print(f"Loaded {len(questions)} questions from {questions_file}")
    return questions


def push_jobs(
    redis_url: str,
    queue_name: str,
    questions: list,
    count: int,
    delay: float = 0.0,
    randomize: bool = True,
):
    """Push jobs to Redis queue."""
    client = redis.from_url(redis_url, decode_responses=True)

    print(f"Pushing {count} jobs to {queue_name}...")
    print(f"  Redis: {redis_url}")
    print(f"  Delay between jobs: {delay}s")
    print()

    start_time = time.time()

    for i in range(count):
        # Select question
        if randomize:
            question = random.choice(questions)
        else:
            question = questions[i % len(questions)]

        # Create job
        job_id = f"job_{uuid.uuid4().hex[:8]}"
        job = {
            "job_id": job_id,
            "question": question,
            "submitted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }

        # Push to queue
        client.lpush(queue_name, json.dumps(job))

        if (i + 1) % 10 == 0 or i == count - 1:
            queue_depth = client.llen(queue_name)
            print(f"  [{i+1}/{count}] Pushed {job_id} | Queue depth: {queue_depth}")

        if delay > 0:
            time.sleep(delay)

    elapsed = time.time() - start_time
    final_depth = client.llen(queue_name)

    print()
    print(f"Done! Pushed {count} jobs in {elapsed:.2f}s")
    print(f"Final queue depth: {final_depth}")
    print()
    print("To check a result:")
    print(f"  redis-cli HGETALL rag:result:{job_id}")


def main():
    parser = argparse.ArgumentParser(
        description="Push RAG jobs to Redis queue for load testing"
    )
    parser.add_argument(
        "-n",
        "--count",
        type=int,
        default=50,
        help="Number of jobs to push (default: 50)",
    )
    parser.add_argument(
        "-d",
        "--delay",
        type=float,
        default=0.0,
        help="Delay between jobs in seconds (default: 0)",
    )
    parser.add_argument(
        "-q",
        "--questions",
        type=str,
        default="./loadgen/sample_questions.txt",
        help="Path to questions file",
    )
    parser.add_argument(
        "--redis-url",
        type=str,
        default="redis://localhost:6379",
        help="Redis URL (default: redis://localhost:6379)",
    )
    parser.add_argument(
        "--queue-name",
        type=str,
        default="rag:jobs",
        help="Queue name (default: rag:jobs)",
    )
    parser.add_argument(
        "--sequential",
        action="store_true",
        help="Use questions sequentially instead of randomly",
    )

    args = parser.parse_args()

    # Load questions
    questions = load_questions(args.questions)

    # Push jobs
    push_jobs(
        redis_url=args.redis_url,
        queue_name=args.queue_name,
        questions=questions,
        count=args.count,
        delay=args.delay,
        randomize=not args.sequential,
    )


if __name__ == "__main__":
    main()
