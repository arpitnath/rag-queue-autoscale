# FAISS: Vector Similarity Search

FAISS (Facebook AI Similarity Search) is a library for efficient similarity search and clustering of dense vectors.

## Why FAISS?

1. **Fast**: Optimized for speed with various index types
2. **Scalable**: Handles billions of vectors
3. **Local**: No external service required
4. **Well-tested**: Used in production at Meta

## Installation

```bash
pip install faiss-cpu  # CPU version
pip install faiss-gpu  # GPU version (requires CUDA)
```

## Basic Usage

### Creating an Index

```python
import faiss
import numpy as np

# Create 1000 vectors of dimension 128
d = 128
vectors = np.random.random((1000, d)).astype('float32')

# Create a flat (brute-force) index
index = faiss.IndexFlatL2(d)

# Add vectors
index.add(vectors)

print(f"Index contains {index.ntotal} vectors")
```

### Searching

```python
# Search for 5 nearest neighbors
query = np.random.random((1, d)).astype('float32')
distances, indices = index.search(query, k=5)

print(f"Nearest neighbors: {indices}")
print(f"Distances: {distances}")
```

## Index Types

### Flat Index (Exact Search)

```python
index = faiss.IndexFlatL2(d)  # L2 distance
index = faiss.IndexFlatIP(d)  # Inner product
```

Best for: Small datasets (<100K vectors)

### IVF Index (Approximate Search)

```python
nlist = 100  # Number of clusters
quantizer = faiss.IndexFlatL2(d)
index = faiss.IndexIVFFlat(quantizer, d, nlist)
index.train(vectors)  # Training required
index.add(vectors)
```

Best for: Medium datasets (100K-10M vectors)

### HNSW Index

```python
index = faiss.IndexHNSWFlat(d, 32)
index.add(vectors)
```

Best for: High recall requirements, fast search

## Saving and Loading

```python
# Save
faiss.write_index(index, "my_index.faiss")

# Load
index = faiss.read_index("my_index.faiss")
```

## With LangChain

LangChain provides a convenient wrapper:

```python
from langchain_community.vectorstores import FAISS
from langchain_community.embeddings import HuggingFaceEmbeddings

# Create embeddings
embeddings = HuggingFaceEmbeddings(
    model_name="sentence-transformers/all-MiniLM-L6-v2"
)

# From documents
vectorstore = FAISS.from_documents(documents, embeddings)

# Save
vectorstore.save_local("./faiss_index")

# Load
vectorstore = FAISS.load_local(
    "./faiss_index", 
    embeddings,
    allow_dangerous_deserialization=True
)

# Search
docs = vectorstore.similarity_search("What is RAG?", k=4)
```

## Performance Considerations

| Index Type | Build Time | Search Time | Memory | Accuracy |
|------------|------------|-------------|--------|----------|
| Flat | Fast | Slow | Low | 100% |
| IVFFlat | Medium | Fast | Low | ~95% |
| HNSW | Slow | Very Fast | High | ~98% |
| IVF-PQ | Fast | Fast | Very Low | ~90% |

## Kubernetes Deployment

When running FAISS in Kubernetes:

1. **Persist the index**: Use PersistentVolume
2. **Build once**: Run indexer as a Job
3. **Share index**: Mount same PVC in all workers
4. **Memory planning**: Index lives in RAM

```yaml
volumes:
  - name: faiss-index
    persistentVolumeClaim:
      claimName: faiss-index-pvc
```

## Best Practices

1. **Normalize vectors** for cosine similarity
2. **Use float32** unless memory-constrained
3. **Train IVF indexes** with representative data
4. **Benchmark** different index types for your use case
