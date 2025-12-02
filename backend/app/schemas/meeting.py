from pydantic import BaseModel
from datetime import datetime
from typing import Optional
from uuid import UUID
from app.models.meeting import MeetingStatus

class MeetingBase(BaseModel):
    title: Optional[str] = None
    platform: Optional[str] = None

class MeetingCreate(MeetingBase):
    pass

class MeetingUpdate(MeetingBase):
    status: Optional[MeetingStatus] = None
    end_time: Optional[datetime] = None

class MeetingInDBBase(MeetingBase):
    id: UUID
    start_time: datetime
    end_time: Optional[datetime] = None
    status: MeetingStatus

    class Config:
        from_attributes = True

class Meeting(MeetingInDBBase):
    pass
