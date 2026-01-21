# Running LLMs with Ollama

Ollama is an easy-to-use tool for running large language models locally. It's perfect for development and testing RAG systems.

## Installation

### macOS

```bash
brew install ollama
```

### Linux

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

### Docker

```bash
docker run -d -v ollama:/root/.ollama -p 11434:11434 ollama/ollama
```

## Basic Usage

### Start the Server

```bash
ollama serve
```

### Pull a Model

```bash
ollama pull mistral
ollama pull llama2
ollama pull codellama
```

### Run Interactively

```bash
ollama run mistral
>>> What is Kubernetes?
```

## API Usage

Ollama provides a REST API at `http://localhost:11434`:

### Generate Endpoint

```bash
curl http://localhost:11434/api/generate -d '{
  "model": "mistral",
  "prompt": "What is RAG?",
  "stream": false
}'
```

### Chat Endpoint

```bash
curl http://localhost:11434/api/chat -d '{
  "model": "mistral",
  "messages": [
    {"role": "user", "content": "Explain KEDA in simple terms"}
  ]
}'
```

## Python Integration

### Direct HTTP

```python
import requests

response = requests.post(
    "http://localhost:11434/api/generate",
    json={
        "model": "mistral",
        "prompt": "What is autoscaling?",
        "stream": False
    }
)
print(response.json()["response"])
```

### With LangChain

```python
from langchain_ollama import OllamaLLM

llm = OllamaLLM(
    base_url="http://localhost:11434",
    model="mistral",
    temperature=0.1
)

response = llm.invoke("Explain vector databases")
print(response)
```

## Docker Networking

When running Ollama on the host and workers in Docker:

### macOS/Windows

```bash
# Workers can reach host via:
OLLAMA_BASE_URL=http://host.docker.internal:11434
```

### Linux

```bash
# Option 1: Host network mode
docker run --network host ...

# Option 2: Use host IP
OLLAMA_BASE_URL=http://172.17.0.1:11434
```

## Model Selection

| Model | Size | Best For |
|-------|------|----------|
| mistral | 4GB | General purpose, fast |
| llama2 | 4GB | Conversation, reasoning |
| codellama | 4GB | Code generation |
| mixtral | 26GB | High quality, slower |

For RAG experiments, `mistral` offers a good balance of quality and speed.

## Performance Tips

1. **GPU acceleration**: Ollama automatically uses GPU if available
2. **Model preloading**: Keep model in memory between requests
3. **Temperature**: Lower values (0.1) for factual responses
4. **Context window**: Default 2048 tokens, increase for long documents

## Kubernetes Deployment

For production, run Ollama as a service:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: ollama
        image: ollama/ollama
        ports:
        - containerPort: 11434
        resources:
          limits:
            nvidia.com/gpu: 1  # If GPU available
```

Note: GPU scheduling requires the NVIDIA device plugin.
