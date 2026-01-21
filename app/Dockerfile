# syntax=docker/dockerfile:1

FROM python:3.11-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Configure pip for better reliability with large packages
ENV PIP_DEFAULT_TIMEOUT=300
ENV PIP_RETRIES=5

# Install Python dependencies
COPY requirements.txt .

# Install dependencies (no torch - using Ollama for embeddings)
RUN pip install --no-cache-dir --user -r requirements.txt

# -----------------------------------------------------------------------------
FROM python:3.11-slim AS runtime

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /root/.local /root/.local
ENV PATH=/root/.local/bin:$PATH

# Copy application code
COPY *.py ./

# Create data directories
RUN mkdir -p /app/data/docs /app/data/faiss_index

# Environment defaults
ENV REDIS_URL=redis://redis:6379 \
    QUEUE_NAME=rag:jobs \
    INDEX_DIR=/app/data/faiss_index \
    DOCS_DIR=/app/data/docs \
    OLLAMA_BASE_URL=http://host.docker.internal:11434 \
    OLLAMA_MODEL=mistral \
    EMBEDDING_MODEL=nomic-embed-text \
    METRICS_PORT=8000

# Expose metrics port
EXPOSE 8000

# Default command: run worker
CMD ["python", "worker.py"]
