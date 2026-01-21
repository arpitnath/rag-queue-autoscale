# LangChain for RAG Applications

LangChain is a framework for developing applications powered by language models. It provides tools for building RAG systems efficiently.

## Core Concepts

### Chains

Chains combine multiple components into a pipeline:

```python
from langchain.chains import LLMChain
from langchain.prompts import PromptTemplate

prompt = PromptTemplate(
    template="Answer this question: {question}",
    input_variables=["question"]
)

chain = LLMChain(llm=llm, prompt=prompt)
result = chain.invoke({"question": "What is KEDA?"})
```

### Document Loaders

Load documents from various sources:

```python
from langchain_community.document_loaders import (
    DirectoryLoader,
    TextLoader,
    PyPDFLoader,
    WebBaseLoader
)

# Load markdown files
loader = DirectoryLoader("./docs", glob="**/*.md")
docs = loader.load()
```

### Text Splitters

Split documents for embedding:

```python
from langchain.text_splitter import RecursiveCharacterTextSplitter

splitter = RecursiveCharacterTextSplitter(
    chunk_size=500,
    chunk_overlap=50
)

chunks = splitter.split_documents(docs)
```

### Embeddings

Convert text to vectors:

```python
from langchain_community.embeddings import HuggingFaceEmbeddings

embeddings = HuggingFaceEmbeddings(
    model_name="sentence-transformers/all-MiniLM-L6-v2"
)

vector = embeddings.embed_query("What is RAG?")
```

### Vector Stores

Store and retrieve embeddings:

```python
from langchain_community.vectorstores import FAISS

vectorstore = FAISS.from_documents(chunks, embeddings)
docs = vectorstore.similarity_search("autoscaling", k=4)
```

## Building a RAG Pipeline

### Complete Example

```python
from langchain_community.document_loaders import DirectoryLoader
from langchain.text_splitter import RecursiveCharacterTextSplitter
from langchain_community.embeddings import HuggingFaceEmbeddings
from langchain_community.vectorstores import FAISS
from langchain_ollama import OllamaLLM
from langchain.prompts import PromptTemplate

# 1. Load documents
loader = DirectoryLoader("./docs", glob="**/*.md")
docs = loader.load()

# 2. Split into chunks
splitter = RecursiveCharacterTextSplitter(chunk_size=500)
chunks = splitter.split_documents(docs)

# 3. Create embeddings
embeddings = HuggingFaceEmbeddings(
    model_name="sentence-transformers/all-MiniLM-L6-v2"
)

# 4. Create vector store
vectorstore = FAISS.from_documents(chunks, embeddings)

# 5. Initialize LLM
llm = OllamaLLM(model="mistral")

# 6. RAG function
def answer(question: str) -> str:
    # Retrieve context
    relevant_docs = vectorstore.similarity_search(question, k=4)
    context = "\n\n".join([doc.page_content for doc in relevant_docs])
    
    # Generate answer
    prompt = f"""Context: {context}

Question: {question}

Answer based on the context:"""
    
    return llm.invoke(prompt)
```

## Prompt Templates

### RAG Prompt

```python
RAG_PROMPT = PromptTemplate(
    input_variables=["context", "question"],
    template="""Use the following context to answer the question.
If you don't know the answer, say so.

Context:
{context}

Question: {question}

Answer:"""
)
```

## Best Practices

1. **Chunk wisely**: 200-500 tokens, with overlap
2. **Use document metadata**: Source, page number, etc.
3. **Retry on errors**: LLM calls can fail
4. **Cache embeddings**: Don't re-embed unchanged docs
5. **Monitor latency**: Track retrieval and generation times

## Error Handling

```python
from langchain.callbacks import get_openai_callback

try:
    with get_openai_callback() as cb:
        result = chain.invoke(input)
        print(f"Tokens used: {cb.total_tokens}")
except Exception as e:
    print(f"Error: {e}")
    # Retry or fallback logic
```

LangChain simplifies RAG development while providing flexibility for production deployments.
