"""
SQLAlchemy Models for macapy.io

This module exports all database models used in the application:
- Meeting: Core meeting entity with lifecycle tracking (in_progress, completed, failed)
- MeetingStatus: Enum for meeting status values
- Transcript: Real-time transcript segments with speaker identification
- ContextDocument: User-uploaded documents (PDF, DOCX, TXT, MD)
- ContextChunk: Chunked documents with vector embeddings for semantic search
- Summary: AI-generated rolling meeting summaries
- Suggestion: AI-generated contextual response suggestions
- TokenUsage: API token consumption tracking per meeting/operation
- UserSettings: Application preference storage

All models use UUID primary keys and include created_at/updated_at timestamps.
"""

from .meeting import Meeting, MeetingStatus
from .transcript import Transcript
from .context import ContextDocument, ContextChunk
from .summary import Summary
from .suggestion import Suggestion
from .token_usage import TokenUsage
from .user_settings import UserSettings

__all__ = [
    "Meeting",
    "MeetingStatus",
    "Transcript",
    "ContextDocument",
    "ContextChunk",
    "Summary",
    "Suggestion",
    "TokenUsage",
    "UserSettings",
]
