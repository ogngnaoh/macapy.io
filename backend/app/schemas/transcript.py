from pydantic import BaseModel
from datetime import datetime
from typing import Optional
from uuid import UUID

# Base schema with common fields
class TranscriptBase(BaseModel):
    meeting_id: UUID
    speaker: Optional[str] = None
    text: str
    timestamp: float

# Schema for creating transcripts (POST request body)
class TranscriptCreate(TranscriptBase):
    pass

# Schema for updating transcripts (PATCH request body)
class TranscriptUpdate(BaseModel):
    speaker: Optional[str] = None
    text: Optional[str] = None
    timestamp: Optional[float] = None

# Base schema for database responses
class TranscriptInDBBase(TranscriptBase):
    id: UUID
    created_at: datetime

    class Config:
        from_attributes = True

# Schema for API responses
class Transcript(TranscriptInDBBase):
    pass
