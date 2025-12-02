"""
Pydantic schemas for AI-related API endpoints.
Includes structured output schemas for OpenAI Responses API.
"""

from pydantic import BaseModel, Field
from typing import Optional, List
from uuid import UUID
from enum import Enum


# =============================================================================
# Enums for Structured Outputs
# =============================================================================

class Priority(str, Enum):
    """Priority level for action items"""
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


class ErrorCode(str, Enum):
    """Error codes for LLM operations"""
    REFUSAL = "refusal"
    RATE_LIMIT = "rate_limit"
    INVALID_INPUT = "invalid_input"
    MODEL_ERROR = "model_error"
    TIMEOUT = "timeout"


# =============================================================================
# Structured Output Schemas for LLM Responses API
# =============================================================================

class ActionItem(BaseModel):
    """Action item extracted from meeting transcript"""
    description: str = Field(..., description="What needs to be done")
    owner: Optional[str] = Field(None, description="Person responsible")
    deadline: Optional[str] = Field(None, description="Due date if mentioned")
    priority: Priority = Field(default=Priority.MEDIUM, description="Priority level")


class Decision(BaseModel):
    """Decision made during the meeting"""
    decision: str = Field(..., description="What was decided")
    context: str = Field(..., description="Why this decision was made")
    stakeholders: List[str] = Field(default_factory=list, description="People involved")


class MeetingSummary(BaseModel):
    """Structured meeting summary output for Responses API"""
    summary: str = Field(..., description="Brief meeting overview (2-3 sentences)")
    key_points: List[str] = Field(..., description="Main discussion points")
    action_items: List[ActionItem] = Field(default_factory=list, description="Tasks to complete")
    decisions: List[Decision] = Field(default_factory=list, description="Decisions made")
    follow_ups: List[str] = Field(default_factory=list, description="Topics for follow-up")


class EnhancedMeetingSummary(BaseModel):
    """
    Enhanced meeting summary with document references for context-aware output.
    Use this schema when documents have been uploaded to provide source attribution.
    """
    summary: str = Field(..., description="Brief meeting overview (2-3 sentences)")
    key_points: List[str] = Field(..., description="Main discussion points")
    action_items: List[ActionItem] = Field(default_factory=list, description="Tasks to complete")
    decisions: List[Decision] = Field(default_factory=list, description="Decisions made")
    follow_ups: List[str] = Field(default_factory=list, description="Topics for follow-up")
    document_references: List[str] = Field(
        default_factory=list,
        description="Documents referenced in discussion (format: 'filename.pdf: relevant content')"
    )
    context_quality: float = Field(
        default=0.8,
        ge=0.0,
        le=1.0,
        description="Confidence that summary captures meeting context accurately"
    )


class QuestionDetection(BaseModel):
    """Detect if transcript contains a question"""
    is_question: bool = Field(..., description="Whether the text contains a question")
    question_text: Optional[str] = Field(None, description="The detected question")
    confidence: float = Field(..., ge=0.0, le=1.0, description="Detection confidence")


class SuggestionResponse(BaseModel):
    """AI-generated response suggestions"""
    question: str = Field(..., description="The detected question")
    suggestions: List[str] = Field(..., description="Response suggestions (1-3)")
    context_used: bool = Field(default=False, description="Whether document context was used")


class EnhancedSuggestionResponse(BaseModel):
    """
    Enhanced suggestion response with document source attribution.
    Provides transparency about which documents informed the suggestions.
    """
    question: str = Field(..., description="The detected question")
    suggestions: List[str] = Field(..., description="Response suggestions (1-3)")
    context_used: bool = Field(default=False, description="Whether document context was used")
    document_sources: List[str] = Field(
        default_factory=list,
        description="Documents that informed these suggestions"
    )
    confidence: float = Field(
        default=0.8,
        ge=0.0,
        le=1.0,
        description="Confidence in suggestion relevance"
    )


class RecapOutput(BaseModel):
    """30-second recap structured output"""
    recap: str = Field(..., description="Brief recap of last 30 seconds")
    key_moment: Optional[str] = Field(None, description="Most important moment")


class QueryResponse(BaseModel):
    """
    Structured response for user queries with source citations.
    Provides transparency about what context informed the answer.
    """
    answer: str = Field(..., description="The AI-generated answer to the query")
    citations: List[str] = Field(
        default_factory=list,
        description="Document sources cited in the answer (format: '[From: filename.pdf]')"
    )
    confidence: float = Field(
        default=0.8,
        ge=0.0,
        le=1.0,
        description="Confidence in answer accuracy based on available context"
    )
    follow_up_questions: List[str] = Field(
        default_factory=list,
        description="Suggested follow-up questions for deeper exploration"
    )
    context_summary: Optional[str] = Field(
        None,
        description="Brief summary of context used to generate the answer"
    )


class LLMErrorDetail(BaseModel):
    """Structured error response from LLM operations"""
    code: ErrorCode = Field(..., description="Error type code")
    message: str = Field(..., description="Human-readable error message")
    recoverable: bool = Field(default=True, description="Whether retry may succeed")
    retry_after: Optional[int] = Field(None, description="Seconds to wait before retry")


class QueryRequest(BaseModel):
    """Request body for AI query endpoint."""
    meeting_id: UUID
    question: str = Field(..., min_length=1, max_length=2000)
    include_documents: bool = True

    class Config:
        json_schema_extra = {
            "example": {
                "meeting_id": "550e8400-e29b-41d4-a716-446655440000",
                "question": "What were the main action items discussed?",
                "include_documents": True
            }
        }


class RecapRequest(BaseModel):
    """Request body for recap endpoint."""
    meeting_id: UUID
    duration_seconds: int = Field(default=30, ge=10, le=300)

    class Config:
        json_schema_extra = {
            "example": {
                "meeting_id": "550e8400-e29b-41d4-a716-446655440000",
                "duration_seconds": 30
            }
        }


class RecapResponse(BaseModel):
    """Response for recap endpoint."""
    recap: str
    tokens_used: int
    transcript_count: int
    time_range: Optional[dict] = None

    class Config:
        json_schema_extra = {
            "example": {
                "recap": "- Discussed project timeline\n- Action item: Review proposal by Friday\n- Question raised about budget allocation",
                "tokens_used": 150,
                "transcript_count": 5,
                "time_range": {
                    "start": "2024-01-15T10:30:00",
                    "end": "2024-01-15T10:30:30"
                }
            }
        }


class SummaryGenerateResponse(BaseModel):
    """Response for manual summary generation."""
    id: int
    content: str
    start_time: Optional[str] = None
    end_time: Optional[str] = None
    created_at: str

    class Config:
        json_schema_extra = {
            "example": {
                "id": 1,
                "content": "- Key decision: Approved Q2 roadmap\n- Action item: Team leads to submit resource plans",
                "start_time": "2024-01-15T10:25:00",
                "end_time": "2024-01-15T10:30:00",
                "created_at": "2024-01-15T10:30:05"
            }
        }


class TokenUsageResponse(BaseModel):
    """Response for token usage endpoint."""
    current_tokens: int
    max_tokens: int
    percentage: float
    breakdown: dict
    warning: bool
    danger: bool

    class Config:
        json_schema_extra = {
            "example": {
                "current_tokens": 45000,
                "max_tokens": 272000,
                "percentage": 16.54,
                "breakdown": {
                    "transcripts": 40000,
                    "summaries": 5000
                },
                "warning": False,
                "danger": False
            }
        }


class QueryEstimateResponse(BaseModel):
    """Response for query cost estimation."""
    query_tokens: int
    context_tokens: int
    estimated_response: int
    total_input: int
    total_estimated: int
