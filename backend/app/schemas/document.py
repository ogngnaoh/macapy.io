from pydantic import BaseModel
from datetime import datetime
from uuid import UUID

class DocumentBase(BaseModel):
    filename: str
    file_type: str

class DocumentResponse(DocumentBase):
    id: int
    meeting_id: UUID
    created_at: datetime

    class Config:
        from_attributes = True
