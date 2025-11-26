import uuid
from datetime import datetime
from enum import Enum
from sqlalchemy import Column, String, DateTime, Enum as SQLEnum
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.db.base import Base

class MeetingStatus(str, Enum):
    PENDING = "PENDING"
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETED = "COMPLETED"

class Meeting(Base):
    __tablename__ = "meetings"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    title = Column(String, nullable=True)
    start_time = Column(DateTime, default=datetime.utcnow)
    end_time = Column(DateTime, nullable=True)
    platform = Column(String, nullable=True) # e.g., "google_meet", "zoom"
    status = Column(SQLEnum(MeetingStatus), default=MeetingStatus.PENDING)

    transcripts = relationship("Transcript", back_populates="meeting", cascade="all, delete-orphan")
    documents = relationship("ContextDocument", back_populates="meeting", cascade="all, delete-orphan")
    summaries = relationship("Summary", back_populates="meeting", cascade="all, delete-orphan")
    suggestions = relationship("Suggestion", back_populates="meeting", cascade="all, delete-orphan")
