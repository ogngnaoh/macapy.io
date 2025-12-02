import os
import shutil
import json
import logging
from dataclasses import dataclass
from typing import List, Optional
from uuid import UUID
from fastapi import UploadFile
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from sqlalchemy.orm import selectinload

from app.models.context import ContextDocument, ContextChunk
from app.services.document_service import DocumentService
from app.services.embedding_service import EmbeddingService

logger = logging.getLogger(__name__)

UPLOAD_DIR = "uploads"
DEFAULT_RELEVANCE_THRESHOLD = 0.70


@dataclass
class ChunkWithMetadata:
    """A document chunk with metadata for source attribution."""
    text: str
    document_id: int
    document_filename: str
    chunk_index: int
    relevance_score: float

class ContextService:
    def __init__(self, db: AsyncSession):
        self.db = db
        self.document_service = DocumentService()
        self.embedding_service = EmbeddingService()
        
        if not os.path.exists(UPLOAD_DIR):
            os.makedirs(UPLOAD_DIR)

    async def process_document(self, meeting_id: UUID, file: UploadFile) -> ContextDocument:
        """
        Uploads, parses, chunks, embeds, and stores a document.
        """
        # 1. Save file locally
        meeting_upload_dir = os.path.join(UPLOAD_DIR, str(meeting_id))
        if not os.path.exists(meeting_upload_dir):
            os.makedirs(meeting_upload_dir)
            
        file_path = os.path.join(meeting_upload_dir, file.filename)
        with open(file_path, "wb") as buffer:
            shutil.copyfileobj(file.file, buffer)
            
        # 2. Parse file
        file_ext = file.filename.split(".")[-1]
        text_content = self.document_service.parse_file(file_path, file_ext)
        
        # 3. Create ContextDocument record
        doc = ContextDocument(
            meeting_id=meeting_id,
            filename=file.filename,
            file_type=file_ext,
            file_path=file_path
        )
        self.db.add(doc)
        await self.db.flush() # Get ID
        
        # 4. Chunk text
        chunks_data = self.document_service.chunk_text(text_content)
        
        # 5. Generate embeddings
        texts = [chunk["text"] for chunk in chunks_data]
        embeddings = await self.embedding_service.generate_embeddings(texts)
        
        # 6. Store chunks
        for i, chunk_data in enumerate(chunks_data):
            chunk = ContextChunk(
                document_id=doc.id,
                chunk_text=chunk_data["text"],
                chunk_index=chunk_data["index"],
                embedding=embeddings[i],
                metadata_json=str(chunk_data) # Simple string storage for now
            )
            self.db.add(chunk)
            
        await self.db.commit()
        await self.db.refresh(doc)
        return doc

    async def get_documents(self, meeting_id: UUID) -> List[ContextDocument]:
        result = await self.db.execute(
            select(ContextDocument).where(ContextDocument.meeting_id == meeting_id)
        )
        return result.scalars().all()

    async def delete_document(self, document_id: int):
        result = await self.db.execute(
            select(ContextDocument).where(ContextDocument.id == document_id)
        )
        doc = result.scalar_one_or_none()
        if doc:
            # Delete file from disk
            if doc.file_path and os.path.exists(doc.file_path):
                os.remove(doc.file_path)
            
            await self.db.delete(doc)
            await self.db.commit()

    async def retrieve_relevant_context(self, meeting_id: UUID, query: str, limit: int = 5) -> List[str]:
        """
        Retrieves relevant text chunks for a given query within a meeting's context.
        """
        query_embedding = await self.embedding_service.generate_embedding(query)

        # Semantic search using pgvector cosine distance (operator <->)
        # We need to join with ContextDocument to filter by meeting_id
        stmt = (
            select(ContextChunk)
            .join(ContextDocument)
            .where(ContextDocument.meeting_id == meeting_id)
            .order_by(ContextChunk.embedding.cosine_distance(query_embedding))
            .limit(limit)
        )

        result = await self.db.execute(stmt)
        chunks = result.scalars().all()

        return [chunk.chunk_text for chunk in chunks]

    async def retrieve_relevant_context_with_metadata(
        self,
        meeting_id: UUID,
        query: str,
        limit: int = 5,
        relevance_threshold: float = DEFAULT_RELEVANCE_THRESHOLD
    ) -> List[ChunkWithMetadata]:
        """
        Retrieves relevant text chunks with metadata and relevance filtering.

        Args:
            meeting_id: Meeting to search within
            query: Query text for semantic search
            limit: Maximum number of chunks to return
            relevance_threshold: Minimum cosine similarity (0-1) to include

        Returns:
            List of ChunkWithMetadata with source attribution and relevance scores
        """
        query_embedding = await self.embedding_service.generate_embedding(query)

        # Query with cosine distance, fetch extra to allow filtering
        stmt = (
            select(
                ContextChunk,
                ContextDocument.filename,
                ContextChunk.embedding.cosine_distance(query_embedding).label('distance')
            )
            .join(ContextDocument)
            .where(ContextDocument.meeting_id == meeting_id)
            .order_by('distance')
            .limit(limit * 2)  # Fetch extra for filtering
        )

        result = await self.db.execute(stmt)
        rows = result.all()

        chunks = []
        for chunk, filename, distance in rows:
            # Convert cosine distance to similarity (cosine distance is 1 - similarity)
            similarity = 1 - distance

            # Skip low-relevance chunks
            if similarity < relevance_threshold:
                logger.debug(f"Skipping chunk from {filename} (relevance={similarity:.2f} < {relevance_threshold})")
                continue

            if len(chunks) >= limit:
                break

            chunks.append(ChunkWithMetadata(
                text=chunk.chunk_text,
                document_id=chunk.document_id,
                document_filename=filename,
                chunk_index=chunk.chunk_index,
                relevance_score=round(similarity, 3)
            ))

        logger.debug(f"retrieve_relevant_context_with_metadata: selected {len(chunks)} from {len(rows)} candidates")
        return chunks
