"""
Pydantic Schemas for macapy.io API

This module exports all Pydantic schemas used for request/response validation:
- Meeting schemas: MeetingCreate, MeetingUpdate, Meeting (response)
- Transcript schemas: TranscriptCreate, Transcript (response)
- Document schemas: DocumentCreate, DocumentUpload, Document (response)

Schemas enforce type validation, provide API documentation, and ensure
consistent data structures across the application.
"""

from .meeting import Meeting, MeetingCreate, MeetingUpdate
from .transcript import Transcript, TranscriptCreate, TranscriptUpdate
from .document import DocumentBase, DocumentResponse

__all__ = [
    "Meeting",
    "MeetingCreate",
    "MeetingUpdate",
    "Transcript",
    "TranscriptCreate",
    "TranscriptUpdate",
    "DocumentBase",
    "DocumentResponse",
]
