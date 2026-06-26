from __future__ import annotations

import os
from pathlib import Path

import chromadb
from pypdf import PdfReader
from sentence_transformers import SentenceTransformer

BASE = Path(os.getenv("RAG_DOCS", "/opt/cerberus_asist/rag/documents"))
DB = os.getenv("RAG_DB", "/opt/cerberus_asist/rag/chroma_db")
MODEL_NAME = os.getenv("EMBED_MODEL", "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2")
CHUNK_SIZE = int(os.getenv("RAG_CHUNK_SIZE", "1000"))

model = SentenceTransformer(MODEL_NAME)
client = chromadb.PersistentClient(path=DB)
collection = client.get_or_create_collection("docs")


def extract_pdf_text(path: Path) -> str:
    reader = PdfReader(str(path))
    pages = [page.extract_text() or "" for page in reader.pages]
    return "\n".join(pages).strip()


def chunk_text(text: str, size: int = CHUNK_SIZE) -> list[str]:
    return [text[i : i + size].strip() for i in range(0, len(text), size) if text[i : i + size].strip()]


def ingest_pdf(path: str) -> int:
    pdf_path = Path(path)
    if not pdf_path.exists() or pdf_path.suffix.lower() != ".pdf":
        return 0

    text = extract_pdf_text(pdf_path)
    if not text:
        return 0

    chunks = chunk_text(text)
    if not chunks:
        return 0

    ids = [f"{pdf_path.stem}-{index}" for index in range(len(chunks))]
    embeddings = model.encode(chunks).tolist()
    collection.upsert(ids=ids, documents=chunks, embeddings=embeddings)
    return len(chunks)


def query(text: str, k: int = 3) -> list[str]:
    embedding = model.encode([text]).tolist()[0]
    result = collection.query(query_embeddings=[embedding], n_results=k)
    return result.get("documents", [[]])[0]
