from sqlalchemy import Column, Integer, String, ForeignKey, DateTime, Text, JSON
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from app.db.base import Base

class Suggestion(Base):
    __tablename__ = "suggestions"

    id = Column(Integer, primary_key=True, index=True)
    meeting_id = Column(UUID(as_uuid=True), ForeignKey("meetings.id"), nullable=False)
    question = Column(Text, nullable=False)
    suggestion_text = Column(Text, nullable=False) # Storing one selected or all as JSON? Let's store the JSON list or individual? 
    # Requirement said "Provide 2-3 response options". 
    # Let's store the full JSON response or a list. 
    # Actually, usually we might want to store them as separate entries or one entry with a list.
    # Let's store as a JSON list for simplicity in one record per "event".
    suggestions_json = Column(JSON, nullable=False) 
    
    context_used = Column(JSON, nullable=True) # IDs of chunks used
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    meeting = relationship("Meeting", back_populates="suggestions")
