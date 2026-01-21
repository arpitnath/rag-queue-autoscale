"""
RAG module: Retrieval-Augmented Generation using FAISS + Ollama.
"""

import os
import time
from pathlib import Path

from langchain_huggingface import HuggingFaceEmbeddings
from langchain_community.vectorstores import FAISS
from langchain_ollama import OllamaLLM
from langchain_core.prompts import PromptTemplate

from metrics import agent_retrieval_latency, agent_llm_latency

# Configuration
INDEX_DIR = os.getenv("INDEX_DIR", "./data/faiss_index")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
OLLAMA_BASE_URL = os.getenv("OLLAMA_BASE_URL", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "mistral")
TOP_K = int(os.getenv("TOP_K", "4"))

# RAG prompt template
RAG_PROMPT = PromptTemplate(
    input_variables=["context", "question"],
    template="""You are a helpful assistant that answers questions based on the provided context.
Use only the information from the context to answer. If the context doesn't contain 
enough information to answer, say "I don't have enough information to answer this question."

Context:
{context}

Question: {question}

Answer:""",
)


class RAGEngine:
    """RAG engine that retrieves context and generates answers."""

    def __init__(self):
        self.vectorstore = None
        self.llm = None
        self._initialized = False

    def initialize(self):
        """Load the FAISS index and initialize the LLM."""
        if self._initialized:
            return

        # Load embeddings model
        print(f"[rag] Loading embedding model: {EMBEDDING_MODEL}")
        embeddings = HuggingFaceEmbeddings(
            model_name=EMBEDDING_MODEL,
            model_kwargs={"device": "cpu"},
            encode_kwargs={"normalize_embeddings": True},
        )

        # Load FAISS index
        index_path = Path(INDEX_DIR)
        if not index_path.exists():
            raise FileNotFoundError(
                f"FAISS index not found at {INDEX_DIR}. Run indexer.py first."
            )

        print(f"[rag] Loading FAISS index from {INDEX_DIR}")
        self.vectorstore = FAISS.load_local(
            str(index_path),
            embeddings,
            allow_dangerous_deserialization=True,
        )

        # Initialize Ollama LLM
        print(
            f"[rag] Connecting to Ollama at {OLLAMA_BASE_URL} (model: {OLLAMA_MODEL})"
        )
        self.llm = OllamaLLM(
            base_url=OLLAMA_BASE_URL,
            model=OLLAMA_MODEL,
            temperature=0.1,
        )

        self._initialized = True
        print("[rag] RAG engine initialized successfully")

    def retrieve(self, question: str, top_k: int = None) -> list:
        """Retrieve relevant documents for a question."""
        if not self._initialized:
            self.initialize()

        top_k = top_k or TOP_K

        start_time = time.time()
        docs = self.vectorstore.similarity_search(question, k=top_k)
        elapsed = time.time() - start_time

        agent_retrieval_latency.observe(elapsed)
        print(f"[rag] Retrieved {len(docs)} docs in {elapsed:.3f}s")

        return docs

    def generate(self, question: str, context_docs: list) -> str:
        """Generate an answer using the LLM."""
        if not self._initialized:
            self.initialize()

        # Format context from retrieved documents
        context = "\n\n---\n\n".join(
            [f"[{i+1}] {doc.page_content}" for i, doc in enumerate(context_docs)]
        )

        # Create prompt
        prompt = RAG_PROMPT.format(context=context, question=question)

        # Generate response
        start_time = time.time()
        response = self.llm.invoke(prompt)
        elapsed = time.time() - start_time

        agent_llm_latency.observe(elapsed)
        print(f"[rag] LLM generated response in {elapsed:.3f}s")

        return response

    def answer(self, question: str) -> dict:
        """Full RAG pipeline: retrieve + generate."""
        if not self._initialized:
            self.initialize()

        # Retrieve relevant context
        docs = self.retrieve(question)

        # Generate answer
        answer = self.generate(question, docs)

        return {
            "question": question,
            "answer": answer,
            "sources": [
                {
                    "content": doc.page_content[:200] + "...",
                    "metadata": doc.metadata,
                }
                for doc in docs
            ],
        }


# Global RAG engine instance
_engine = None


def get_rag_engine() -> RAGEngine:
    """Get or create the global RAG engine instance."""
    global _engine
    if _engine is None:
        _engine = RAGEngine()
    return _engine
