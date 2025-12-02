import uuid
from sqlalchemy import Column, Integer, String, ForeignKey, DateTime, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from pgvector.sqlalchemy import Vector
from app.db.base import Base

class ContextDocument(Base):
    __tablename__ = "context_documents"

    id = Column(Integer, primary_key=True, index=True)
    meeting_id = Column(UUID(as_uuid=True), ForeignKey("meetings.id"), nullable=False)
    filename = Column(String, nullable=False)
    file_type = Column(String, nullable=False)
    file_path = Column(String, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    # Relationships
    meeting = relationship("Meeting", back_populates="documents")
    chunks = relationship("ContextChunk", back_populates="document", cascade="all, delete-orphan")

class ContextChunk(Base):
    __tablename__ = "context_chunks"

    id = Column(Integer, primary_key=True, index=True)
    document_id = Column(Integer, ForeignKey("context_documents.id"), nullable=False)
    chunk_text = Column(Text, nullable=False)
    chunk_index = Column(Integer, nullable=False)
    embedding = Column(Vector(1536)) # OpenAI embedding dimension
    metadata_json = Column(Text, nullable=True)
    
    # Relationships
    document = relationship("ContextDocument", back_populates="chunks")
