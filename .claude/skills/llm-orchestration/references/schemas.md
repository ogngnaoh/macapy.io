# Pydantic Schemas for Meeting Assistant

## Table of Contents
1. [Core Schemas](#core-schemas)
2. [Extraction Schemas](#extraction-schemas)
3. [Reasoning Schemas](#reasoning-schemas)

---

## Core Schemas

### MeetingSummary

```python
from pydantic import BaseModel, Field
from typing import Optional, List
from enum import Enum

class ActionItemPriority(str, Enum):
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"

class ActionItem(BaseModel):
    """Single action item from a meeting"""
    task: str = Field(..., description="Concise description of what needs to be done")
    owner: str = Field(..., description="Person responsible")
    due_date: Optional[str] = Field(None, description="YYYY-MM-DD or null")
    priority: ActionItemPriority = Field(default=ActionItemPriority.MEDIUM)
    depends_on: List[str] = Field(default_factory=list, description="IDs of dependencies")

class Decision(BaseModel):
    """Key decision made during meeting"""
    title: str = Field(..., description="Decision title")
    context: str = Field(..., description="Why this decision was made")
    chosen_option: str = Field(..., description="What was decided")
    alternatives_considered: List[str] = Field(default_factory=list)
    approvers: List[str] = Field(..., description="Who approved")

class MeetingSummary(BaseModel):
    """Complete structured meeting summary"""
    title: str = Field(..., description="Meeting title")
    date: str = Field(..., description="YYYY-MM-DD")
    attendees: List[str] = Field(..., description="Attendee names")
    duration_minutes: int = Field(..., description="Duration in minutes")
    objectives: List[str] = Field(..., description="Meeting objectives")
    summary: str = Field(..., description="100-200 word summary")
    action_items: List[ActionItem] = Field(...)
    decisions: List[Decision] = Field(...)
    follow_up_topics: List[str] = Field(default_factory=list)
    next_meeting_suggested: bool = Field(default=False)
```

---

## Extraction Schemas

### QuickActionExtraction (for streaming)

```python
class QuickActionExtraction(BaseModel):
    """Fast extraction for real-time display"""
    action: str = Field(..., description="What needs to be done")
    owner: Optional[str] = Field(None, description="Who is responsible")
    urgency_level: str = Field(
        default="normal",
        enum=["low", "normal", "high", "critical"]
    )
    confidence: float = Field(
        ..., ge=0.0, le=1.0,
        description="Model confidence (0-1)"
    )
```

### SegmentExtraction (per-chunk processing)

```python
class SegmentExtraction(BaseModel):
    """Extraction from a single transcript segment"""
    segment_id: str = Field(...)
    topics_discussed: List[str] = Field(...)
    action_items: List[ActionItem] = Field(default_factory=list)
    decisions: List[Decision] = Field(default_factory=list)
    questions_raised: List[str] = Field(default_factory=list)
    key_quotes: List[str] = Field(default_factory=list)
```

### NormalizedTranscript

```python
class Speaker(BaseModel):
    id: str = Field(..., description="Speaker identifier")
    name: Optional[str] = Field(None)
    role: Optional[str] = Field(None)

class NormalizedTranscript(BaseModel):
    """Cleaned and structured transcript"""
    speakers: List[Speaker] = Field(...)
    normalized_text: str = Field(..., description="Cleaned transcript")
    detected_language: str = Field(default="en")
    confidence_score: float = Field(..., ge=0.0, le=1.0)
```

---

## Reasoning Schemas

### AnalysisWithReasoning (chain-of-thought)

```python
class ReasoningStep(BaseModel):
    step_number: int
    description: str
    logic: str = Field(..., description="Explain reasoning")
    provisional_conclusion: Optional[str] = None

class AnalysisWithReasoning(BaseModel):
    """Structured chain-of-thought output"""
    reasoning_steps: List[ReasoningStep]
    final_conclusion: str
    confidence: float = Field(ge=0, le=1)
```

### VerificationResult (multi-agent)

```python
class VerificationResult(BaseModel):
    """Output from verification agent"""
    extracted_action: str
    is_valid: bool
    confidence: float = Field(ge=0, le=1)
    reasoning: str
    suggested_correction: Optional[str] = None
```

---

## Schema Design Checklist

- [ ] All fields have `description` in Field()
- [ ] Optional fields use `Optional[T]` with `None` default
- [ ] Enums for constrained values (priority, urgency, status)
- [ ] Lists have `default_factory=list` not `default=[]`
- [ ] Numeric constraints with `ge`, `le`, `gt`, `lt`
- [ ] Date formats documented (YYYY-MM-DD)
