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
# TODO: Uncomment when implemented
# from .transcript import Transcript, TranscriptCreate
# from .document import Document, DocumentCreate, DocumentUpload

__all__ = [
    "Meeting",
    "MeetingCreate",
    "MeetingUpdate",
    # "Transcript", "TranscriptCreate",
    # "Document", "DocumentCreate", "DocumentUpload",
]
