"""
Token Usage Model for tracking API token consumption.
"""

from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship
from app.db.base import Base


class TokenUsage(Base):
    """
    Tracks token usage per API call for monitoring and billing purposes.

    Attributes:
        id: Primary key
        meeting_id: Reference to the meeting
        source: Type of operation ('transcript', 'query', 'summary', 'suggestion')
        input_tokens: Number of input tokens consumed
        output_tokens: Number of output tokens generated
        model: The model used for the operation
        created_at: When the usage was recorded
    """
    __tablename__ = "token_usage"

    id = Column(Integer, primary_key=True, index=True)
    meeting_id = Column(UUID(as_uuid=True), ForeignKey("meetings.id", ondelete="CASCADE"), nullable=False, index=True)
    source = Column(String(50), nullable=False, index=True)
    input_tokens = Column(Integer, nullable=False, default=0)
    output_tokens = Column(Integer, nullable=False, default=0)
    model = Column(String(100), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=text("now()"))

    # Relationship
    meeting = relationship("Meeting", back_populates="token_usages")

    def __repr__(self):
        return f"<TokenUsage(id={self.id}, meeting={self.meeting_id}, source={self.source}, tokens={self.input_tokens + self.output_tokens})>"

    @property
    def total_tokens(self) -> int:
        """Total tokens (input + output)."""
        return self.input_tokens + self.output_tokens
