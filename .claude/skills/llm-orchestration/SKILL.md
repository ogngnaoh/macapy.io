---
name: llm-orchestration
description: |
  Implement core LLM logic and orchestration for the macapy.io agentic meeting assistant using OpenAI's Responses API with structured outputs. Use when: (1) implementing LLM service methods for transcription processing, (2) creating Pydantic schemas for meeting data extraction, (3) building multi-step orchestration pipelines, (4) adding streaming responses for real-time UI, (5) implementing chain-of-thought reasoning, (6) handling LLM errors and refusals, (7) adding RAG-style context retrieval, or (8) any backend work involving GPT-5-nano or structured outputs.
---

# LLM Orchestration for Agentic Meeting Assistant

## Architecture Overview

```
MeetingOrchestratorService  →  Multi-step pipeline orchestration
StructuredResponseService   →  Schema registry + validated extraction
DataPipelineService         →  Audio → Transcript → Chunks → Embeddings
```

## Quick Reference

### OpenAI Responses API Pattern

```python
from openai import OpenAI
from pydantic import BaseModel, Field

client = OpenAI()

class MySchema(BaseModel):
    field1: str = Field(..., description="Clear description")
    field2: int

response = client.responses.parse(
    model="gpt-5-nano-2025-08-07",
    input=[
        {"role": "system", "content": "System prompt"},
        {"role": "user", "content": "User input"}
    ],
    text_format=MySchema
)

result = response.output_parsed  # Typed object
```

### API Selection Guide

| Responses API | Chat Completions |
|--------------|------------------|
| Meeting summaries with guaranteed fields | Follow-up questions |
| Action item/decision extraction | Free-form reasoning |
| Schema-compliant structured output | Interactive clarification |

## Reference Files

- [references/schemas.md](references/schemas.md) - Pydantic schema definitions
- [references/services.md](references/services.md) - Service layer implementations
- [references/orchestration.md](references/orchestration.md) - Pipeline patterns
- [references/error-handling.md](references/error-handling.md) - Error handling strategies

## Key Constraints

### Schema Design Rules
- All fields `required` (use `Optional[T]` for nullables)
- Always `additionalProperties: false`
- Clear descriptions for every field
- Use enums for constrained values

### Token Management
- Segment transcripts at ~2000 words
- Use embeddings + RAG for context retrieval
- Track usage via `token_service.py`

### Streaming Requirements
- Use streaming for operations >3s latency
- SSE format: `data: {"chunk": "..."}\n\n`
- Async generators for response streaming

## Integration Points

**Backend Services:**
- `backend/app/services/llm_service.py` - LLM calls
- `backend/app/services/query_service.py` - Query streaming
- `backend/app/services/token_service.py` - Token counting

**Database Models:**
- `transcripts` - Segments with timestamps
- `summaries` - Rolling summaries (30s interval)
- `suggestions` - AI response suggestions
- `token_usage` - Consumption tracking
