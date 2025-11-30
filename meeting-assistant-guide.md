# Comprehensive Guide: Building Agentic Meeting Assistants with GPT-5-Nano-2025-08-07

## 1. Architecture Overview

### Core Principles for Agentic Meeting Assistants

An agentic meeting assistant orchestrates multiple LLM calls, tool integrations, and structured workflows to:
- **Parse** audio/transcripts into meaningful semantic blocks
- **Extract** action items, decisions, and summaries
- **Reason** about context and generate context-aware responses
- **Synthesize** outputs following strict schemas for reliable downstream processing

### Two-Layer Architecture Pattern

```
┌─────────────────────────────────────────────────────────────────┐
│                    User Interface Layer                         │
│             (Desktop App: Electron + React + TypeScript)        │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Services Layer (Core Logic)                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Meeting Orchestrator Service                           │   │
│  │  - Manages conversation flow                            │   │
│  │  - Handles LLM request batching                         │   │
│  │  - Manages state between calls                          │   │
│  └──────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Structured Response Service                            │   │
│  │  - Validates JSON Schema compliance                     │   │
│  │  - Transforms LLM outputs to domain models              │   │
│  │  - Handles refusals and error cases                     │   │
│  └──────────────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Data Pipeline Service                                  │   │
│  │  - Audio transcription → Chunks                         │   │
│  │  - Embedding generation for semantic search             │   │
│  │  - Context retrieval (RAG-style)                        │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    LLM API Layer                                │
│              OpenAI Responses API (gpt-5-nano)                 │
│  - Structured Outputs with JSON Schema                         │
│  - Function Calling for tool invocation                        │
│  - Streaming for real-time feedback                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Using the OpenAI Responses API (GPT-5-Nano)

### Key Differences: Responses API vs Chat Completions API

| Feature | Responses API | Chat Completions |
|---------|---------------|-----------------|
| **Primary Use** | Structured output generation | General conversational response |
| **Guarantee** | Adheres to exact JSON Schema | No schema guarantee |
| **Input Format** | `input` (message array) | `messages` (message array) |
| **Output Format** | `output_parsed` (typed object) | `choices[0].message.content` (string) |
| **Schema Definition** | Pydantic models or Zod | N/A |
| **Best For** | Reliable extraction, meeting summaries | Chat, reasoning, exploration |

### When to Use Each Endpoint

**Use Responses API for:**
- Meeting summaries with guaranteed fields (action_items, decisions, attendees)
- Structured note extraction from unstructured audio
- Reliable state management in multi-turn workflows
- UI generation from unstructured content

**Use Chat Completions API for:**
- Follow-up questions about meeting content
- Free-form reasoning about decisions
- Interactive clarification during transcription

### Setting Up the Responses API Client

```python
from openai import OpenAI
import os

client = OpenAI(
    api_key=os.getenv('OPENAI_API_KEY'),
    # Optional: set organization if needed
    # organization=os.getenv('OPENAI_ORG_ID')
)

# For gpt-5-nano specifically
MODEL = "gpt-5-nano-2025-08-07"
```

---

## 3. Designing Schemas for Meeting Assistant Outputs

### Core Pattern: Pydantic BaseModel + Responses API

The Responses API guarantees that output matches your schema exactly. This eliminates parsing errors and validation loops.

#### Schema Design Principles

1. **Clarity Over Flexibility**: Every field should have explicit meaning
2. **Exhaustiveness**: Include null union types for optional-like fields
3. **Nesting**: Use objects for grouped data, but limit to ~5000 total properties per schema
4. **Validation**: Add constraints (patterns, min/max) to guide model behavior

### Example 1: Meeting Summary Schema

```python
from pydantic import BaseModel, Field
from typing import Optional, List
from enum import Enum

class ActionItemPriority(str, Enum):
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"

class ActionItem(BaseModel):
    """Represents a single action item from a meeting"""
    task: str = Field(..., description="Concise description of what needs to be done")
    owner: str = Field(..., description="Name of person responsible for this action")
    due_date: Optional[str] = Field(
        None, 
        description="Expected completion date (YYYY-MM-DD format or null if not specified)"
    )
    priority: ActionItemPriority = Field(
        default=ActionItemPriority.MEDIUM,
        description="Priority level of this action"
    )
    depends_on: List[str] = Field(
        default_factory=list,
        description="List of action item IDs this depends on"
    )

class Decision(BaseModel):
    """Represents a key decision made during the meeting"""
    title: str = Field(..., description="Title of the decision")
    context: str = Field(..., description="Why this decision was made")
    chosen_option: str = Field(..., description="What was decided")
    alternatives_considered: List[str] = Field(
        default_factory=list,
        description="Other options that were discussed"
    )
    approvers: List[str] = Field(..., description="Who approved this decision")

class MeetingSummary(BaseModel):
    """Complete structured summary of a meeting"""
    title: str = Field(..., description="Title of the meeting")
    date: str = Field(..., description="Meeting date (YYYY-MM-DD)")
    attendees: List[str] = Field(..., description="List of attendees' names")
    duration_minutes: int = Field(..., description="Meeting duration in minutes")
    objectives: List[str] = Field(
        ..., 
        description="What the meeting was supposed to accomplish"
    )
    summary: str = Field(
        ..., 
        description="Paragraph summary of what was discussed (100-200 words)"
    )
    action_items: List[ActionItem] = Field(
        ..., 
        description="All action items identified during the meeting"
    )
    decisions: List[Decision] = Field(
        ..., 
        description="All key decisions made during the meeting"
    )
    follow_up_topics: List[str] = Field(
        default_factory=list,
        description="Topics that need follow-up discussion"
    )
    next_meeting_suggested: bool = Field(
        default=False,
        description="Whether a follow-up meeting was suggested"
    )
```

### Example 2: Streaming Action Item Extraction

For real-time feedback during transcription, use a simpler schema:

```python
class QuickActionExtraction(BaseModel):
    """Fast extraction for real-time display"""
    action: str = Field(..., description="What needs to be done")
    owner: Optional[str] = Field(None, description="Who is responsible (if mentioned)")
    urgency_level: str = Field(
        default="normal",
        enum=["low", "normal", "high", "critical"]
    )
    confidence: float = Field(
        ..., 
        ge=0.0, 
        le=1.0,
        description="Model's confidence this is actually an action item (0-1)"
    )
```

---

## 4. Structured Outputs with Responses API

### Core API Pattern

```python
from openai import OpenAI
from pydantic import BaseModel

client = OpenAI()

# Define your schema
class MySchema(BaseModel):
    field1: str
    field2: int

# Call the API
response = client.responses.parse(
    model="gpt-5-nano-2025-08-07",
    input=[
        {
            "role": "system",
            "content": "You are a meeting assistant..."
        },
        {
            "role": "user",
            "content": "Summarize this meeting transcript: [transcript]"
        }
    ],
    text_format=MySchema  # Automatically converted to JSON Schema
)

# Access the parsed output
summary = response.output_parsed
print(summary.field1)
```

### Advanced: Using JSON Schema Directly (REST API)

```python
import requests
import json

schema = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "action_items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "task": {"type": "string"},
                    "owner": {"type": "string"}
                },
                "required": ["task", "owner"],
                "additionalProperties": False
            }
        }
    },
    "required": ["summary", "action_items"],
    "additionalProperties": False
}

response = requests.post(
    "https://api.openai.com/v1/responses",
    headers={
        "Authorization": f"Bearer {os.getenv('OPENAI_API_KEY')}",
        "Content-Type": "application/json"
    },
    json={
        "model": "gpt-5-nano-2025-08-07",
        "input": [
            {"role": "system", "content": "You are a meeting assistant."},
            {"role": "user", "content": "Summarize: ..."}
        ],
        "text": {
            "format": {
                "type": "json_schema",
                "name": "meeting_summary",
                "schema": schema,
                "strict": True
            }
        }
    }
)

result = response.json()
parsed_output = result["output"][0]["content"][0]["text"]
```

---

## 5. Service Layer Implementation Architecture

### 5.1 Meeting Orchestrator Service

Manages the overall flow of meeting processing:

```python
from typing import Optional, List
from dataclasses import dataclass
from datetime import datetime

@dataclass
class ProcessingContext:
    """Maintains state across multiple LLM calls"""
    meeting_id: str
    transcript: str
    intermediate_extractions: dict = None  # Cache for incremental results
    conversation_history: List[dict] = None
    
    def __post_init__(self):
        if self.conversation_history is None:
            self.conversation_history = []

class MeetingOrchestratorService:
    def __init__(self, client: OpenAI, model: str = "gpt-5-nano-2025-08-07"):
        self.client = client
        self.model = model
    
    async def process_meeting(self, 
                              transcript: str,
                              meeting_id: str,
                              quick_extraction: bool = False) -> dict:
        """
        Orchestrates the complete meeting processing pipeline
        
        Args:
            transcript: Raw meeting transcript
            meeting_id: Unique identifier for this meeting
            quick_extraction: If True, do streaming extraction for real-time updates
        
        Returns:
            Structured meeting summary
        """
        ctx = ProcessingContext(
            meeting_id=meeting_id,
            transcript=transcript
        )
        
        # Step 1: Identify speakers and normalize transcript
        ctx = await self._normalize_transcript(ctx)
        
        # Step 2: Extract segments (if meeting is long)
        segments = await self._segment_transcript(ctx)
        
        # Step 3: Extract from each segment (parallelizable)
        segment_summaries = await self._process_segments(segments, ctx)
        
        # Step 4: Synthesize into final output
        final_summary = await self._synthesize_summary(
            segment_summaries, 
            ctx
        )
        
        return final_summary
    
    async def _normalize_transcript(self, ctx: ProcessingContext) -> ProcessingContext:
        """Clean and structure raw transcript"""
        response = self.client.responses.parse(
            model=self.model,
            input=[
                {
                    "role": "system",
                    "content": "You are an expert at normalizing meeting transcripts. Clean up speech-to-text errors, identify speakers clearly, and format the transcript."
                },
                {
                    "role": "user",
                    "content": f"Normalize this transcript:\n\n{ctx.transcript}"
                }
            ],
            text_format=NormalizedTranscript  # Define this schema
        )
        ctx.transcript = response.output_parsed.normalized_text
        return ctx
    
    async def _segment_transcript(self, ctx: ProcessingContext) -> List[str]:
        """Break long transcripts into manageable chunks"""
        # Simple approach: split by time or word count
        words = ctx.transcript.split()
        chunk_size = 2000  # words
        segments = [
            ' '.join(words[i:i+chunk_size])
            for i in range(0, len(words), chunk_size)
        ]
        return segments
    
    async def _process_segments(self, 
                                segments: List[str],
                                ctx: ProcessingContext) -> List[dict]:
        """Process each segment independently (parallelizable)"""
        summaries = []
        
        for i, segment in enumerate(segments):
            response = self.client.responses.parse(
                model=self.model,
                input=[
                    {
                        "role": "system",
                        "content": """Extract structured information from this meeting segment.
                        Focus on: action items, decisions, key topics discussed."""
                    },
                    {
                        "role": "user",
                        "content": f"Segment {i+1}/{len(segments)}:\n\n{segment}"
                    }
                ],
                text_format=SegmentExtraction  # Define this schema
            )
            summaries.append(response.output_parsed.dict())
        
        return summaries
    
    async def _synthesize_summary(self,
                                  segment_summaries: List[dict],
                                  ctx: ProcessingContext) -> MeetingSummary:
        """Combine segment summaries into final output"""
        combined_text = self._combine_segment_data(segment_summaries)
        
        response = self.client.responses.parse(
            model=self.model,
            input=[
                {
                    "role": "system",
                    "content": """You are an expert meeting analyst. 
                    Synthesize the provided segment summaries into a cohesive meeting summary.
                    Deduplicate action items, merge related decisions, identify patterns."""
                },
                {
                    "role": "user",
                    "content": f"Synthesize these segment summaries:\n\n{combined_text}"
                }
            ],
            text_format=MeetingSummary
        )
        
        return response.output_parsed
```

### 5.2 Structured Response Service

Handles schema management and response validation:

```python
from enum import Enum
import json

class ResponseType(str, Enum):
    MEETING_SUMMARY = "meeting_summary"
    ACTION_EXTRACTION = "action_extraction"
    DECISION_LOG = "decision_log"
    QUICK_FEEDBACK = "quick_feedback"

class StructuredResponseService:
    """
    Centralizes schema definitions and response handling
    """
    
    # Schema Registry (single source of truth)
    SCHEMAS = {
        ResponseType.MEETING_SUMMARY: MeetingSummary,
        ResponseType.ACTION_EXTRACTION: ActionItem,
        ResponseType.DECISION_LOG: Decision,
        ResponseType.QUICK_FEEDBACK: QuickActionExtraction,
    }
    
    def __init__(self, client: OpenAI):
        self.client = client
    
    def get_schema(self, response_type: ResponseType) -> type:
        """Get Pydantic model for a response type"""
        return self.SCHEMAS[response_type]
    
    async def extract(self, 
                     text: str,
                     response_type: ResponseType,
                     system_prompt: str = None,
                     context: dict = None) -> dict:
        """
        Generic extraction method with error handling
        
        Args:
            text: Input text to extract from
            response_type: What schema to use
            system_prompt: Custom system prompt (optional)
            context: Additional context for the model
        """
        
        schema_class = self.get_schema(response_type)
        
        if not system_prompt:
            system_prompt = self._get_default_prompt(response_type)
        
        try:
            response = self.client.responses.parse(
                model="gpt-5-nano-2025-08-07",
                input=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": text}
                ],
                text_format=schema_class
            )
            
            # Check for refusal
            if response.refusal:
                return {
                    "status": "refused",
                    "reason": response.refusal,
                    "data": None
                }
            
            return {
                "status": "success",
                "data": response.output_parsed.dict(),
                "model": response.model,
                "usage": {
                    "input_tokens": response.usage.prompt_tokens,
                    "output_tokens": response.usage.completion_tokens
                }
            }
            
        except Exception as e:
            return {
                "status": "error",
                "error": str(e),
                "data": None
            }
    
    def _get_default_prompt(self, response_type: ResponseType) -> str:
        prompts = {
            ResponseType.MEETING_SUMMARY: 
                "You are a professional meeting analyst. Extract and structure all relevant information from the meeting transcript.",
            ResponseType.ACTION_EXTRACTION: 
                "Identify all action items that need to be done following this meeting.",
            ResponseType.DECISION_LOG: 
                "Document all key decisions made during this meeting with context.",
            ResponseType.QUICK_FEEDBACK: 
                "Quickly identify urgent action items for real-time display."
        }
        return prompts.get(response_type, "Extract structured information from the provided text.")
```

### 5.3 Data Pipeline Service

Handles transcription, chunking, and context retrieval:

```python
import hashlib
from typing import List, Tuple

class DataPipelineService:
    """
    Manages audio processing, transcription, and context preparation
    """
    
    def __init__(self, client: OpenAI, db_service=None):
        self.client = client
        self.db_service = db_service  # For storing embeddings
    
    async def prepare_meeting_context(self,
                                      audio_path: str) -> dict:
        """
        Complete pipeline: audio → transcript → structured chunks → embeddings
        """
        
        # Step 1: Transcribe audio
        transcript = await self._transcribe_audio(audio_path)
        
        # Step 2: Split into semantic chunks
        chunks = self._create_semantic_chunks(transcript)
        
        # Step 3: Generate embeddings for context retrieval
        embeddings = await self._embed_chunks(chunks)
        
        # Step 4: Store for later retrieval
        if self.db_service:
            await self.db_service.store_meeting_chunks(
                transcript,
                chunks,
                embeddings
            )
        
        return {
            "transcript": transcript,
            "chunks": chunks,
            "embeddings": embeddings
        }
    
    async def _transcribe_audio(self, audio_path: str) -> str:
        """
        Transcribe audio file using OpenAI Whisper API
        """
        with open(audio_path, "rb") as f:
            transcript = self.client.audio.transcriptions.create(
                model="whisper-1",
                file=f,
                language="en"
            )
        return transcript.text
    
    def _create_semantic_chunks(self, transcript: str) -> List[dict]:
        """
        Split transcript into semantically meaningful chunks
        (not just by word count)
        """
        chunks = []
        current_chunk = ""
        current_topics = []
        chunk_id = 0
        
        sentences = transcript.split(". ")
        
        for sentence in sentences:
            current_chunk += sentence + ". "
            
            # Chunk size: ~500 words or detected topic shift
            if len(current_chunk.split()) > 500:
                chunks.append({
                    "id": f"chunk_{chunk_id}",
                    "text": current_chunk,
                    "topics": self._detect_topics(current_chunk),
                    "word_count": len(current_chunk.split())
                })
                current_chunk = ""
                chunk_id += 1
        
        # Don't lose the last chunk
        if current_chunk.strip():
            chunks.append({
                "id": f"chunk_{chunk_id}",
                "text": current_chunk,
                "topics": self._detect_topics(current_chunk),
                "word_count": len(current_chunk.split())
            })
        
        return chunks
    
    async def _embed_chunks(self, chunks: List[dict]) -> List[List[float]]:
        """
        Generate embeddings for semantic search during context retrieval
        
        Later: retrieve relevant chunks using similarity search
        """
        texts = [c["text"] for c in chunks]
        
        response = self.client.embeddings.create(
            model="text-embedding-3-small",  # Fast & cost-effective
            input=texts
        )
        
        return [item.embedding for item in response.data]
    
    def _detect_topics(self, text: str) -> List[str]:
        """
        Quick topic detection (can be enhanced with LLM)
        """
        # Simple keyword matching for MVP
        keywords = {
            "budget": ["budget", "cost", "expense", "pricing"],
            "timeline": ["deadline", "schedule", "timeline", "when"],
            "resource": ["resource", "team", "personnel", "staff"],
            "risk": ["risk", "issue", "problem", "concern"]
        }
        
        detected = []
        text_lower = text.lower()
        
        for topic, keywords_list in keywords.items():
            if any(kw in text_lower for kw in keywords_list):
                detected.append(topic)
        
        return detected
    
    async def retrieve_context(self,
                               query: str,
                               chunks: List[dict],
                               embeddings: List[List[float]],
                               top_k: int = 3) -> str:
        """
        RAG-style context retrieval: find most relevant chunks for a query
        """
        # Embed the query
        query_embedding = self.client.embeddings.create(
            model="text-embedding-3-small",
            input=query
        ).data[0].embedding
        
        # Cosine similarity search
        from numpy import dot
        from numpy.linalg import norm
        
        similarities = [
            dot(query_embedding, emb) / (norm(query_embedding) * norm(emb))
            for emb in embeddings
        ]
        
        # Get top-k
        top_indices = sorted(
            range(len(similarities)),
            key=lambda i: similarities[i],
            reverse=True
        )[:top_k]
        
        # Combine relevant chunks
        context = "\n\n".join([
            chunks[i]["text"] for i in top_indices
        ])
        
        return context
```

---

## 6. Designing for LLM Logic Reliability

### 6.1 Chain-of-Thought for Complex Decisions

Use structured intermediate reasoning:

```python
class ReasoningStep(BaseModel):
    step_number: int
    description: str
    logic: str  # Explain the reasoning
    provisional_conclusion: Optional[str]

class AnalysisWithReasoning(BaseModel):
    reasoning_steps: List[ReasoningStep]
    final_conclusion: str
    confidence: float = Field(ge=0, le=1)

# Service method
async def analyze_decision_with_reasoning(self,
                                         decision_text: str) -> dict:
    response = self.client.responses.parse(
        model="gpt-5-nano-2025-08-07",
        input=[
            {
                "role": "system",
                "content": """Analyze the following decision step-by-step.
                For each step:
                1. Describe what you're analyzing
                2. Explain the logic
                3. State provisional conclusion
                Then provide final conclusion."""
            },
            {"role": "user", "content": decision_text}
        ],
        text_format=AnalysisWithReasoning
    )
    
    return response.output_parsed.dict()
```

### 6.2 Multi-Agent Patterns for Reliability

Use multiple agents to verify outputs (voting/consensus):

```python
class VerificationResult(BaseModel):
    extracted_action: str
    is_valid: bool
    confidence: float
    reasoning: str

class AnalystAgent:
    """Agent 1: Initial extraction"""
    async def extract(self, text: str) -> dict:
        # ... extraction logic
        pass

class VerifierAgent:
    """Agent 2: Verification"""
    async def verify(self, extraction: dict, original_text: str) -> VerificationResult:
        response = self.client.responses.parse(
            model="gpt-5-nano-2025-08-07",
            input=[
                {
                    "role": "system",
                    "content": "Verify if this extracted action is valid and aligns with the original text."
                },
                {
                    "role": "user",
                    "content": f"Extracted: {extraction}\n\nOriginal: {original_text}"
                }
            ],
            text_format=VerificationResult
        )
        return response.output_parsed

class ConsensusOrchestrator:
    """Orchestrate multiple agents"""
    def __init__(self, analyzer: AnalystAgent, verifier: VerifierAgent):
        self.analyzer = analyzer
        self.verifier = verifier
    
    async def extract_with_verification(self, text: str) -> dict:
        # Get initial extraction
        extraction = await self.analyzer.extract(text)
        
        # Verify it
        verification = await self.verifier.verify(extraction, text)
        
        return {
            "extraction": extraction,
            "verification": verification,
            "is_reliable": verification.confidence > 0.8
        }
```

### 6.3 Error Handling & Refusal Management

```python
class RefusalHandler:
    @staticmethod
    def should_rephrase(refusal: str) -> bool:
        """Determine if we should rephrase and retry"""
        safety_keywords = ["policy", "guidelines", "cannot help"]
        return any(kw in refusal.lower() for kw in safety_keywords)
    
    @staticmethod
    def get_rephrased_prompt(original: str, refusal: str) -> str:
        """Rephrase prompt to work around refusal"""
        # Example: if refused PII extraction, ask for anonymized version
        rephrasing_strategies = {
            "PII": "Please extract names as 'Person A', 'Person B', etc.",
            "confidential": "Extract the business logic without proprietary details",
        }
        # Implement logic to choose strategy based on refusal
        return original

# In service
async def extract_with_retry(self, text: str) -> dict:
    response = self.client.responses.parse(
        model="gpt-5-nano-2025-08-07",
        input=[...],
        text_format=MeetingSummary
    )
    
    if response.refusal:
        if RefusalHandler.should_rephrase(response.refusal):
            # Retry with rephrased prompt
            new_prompt = RefusalHandler.get_rephrased_prompt(
                original_prompt, 
                response.refusal
            )
            # Retry...
        else:
            # Log and return partial result
            return {"status": "refused", "reason": response.refusal}
    
    return {"status": "success", "data": response.output_parsed}
```

---

## 7. Streaming for Real-Time Feedback

Use streaming for long-running operations:

```python
from openai import OpenAI

async def stream_action_items(self, transcript: str):
    """
    Stream action items one-by-one for real-time UI updates
    """
    with self.client.responses.stream(
        model="gpt-5-nano-2025-08-07",
        input=[
            {"role": "system", "content": "Extract action items..."},
            {"role": "user", "content": transcript}
        ],
        text_format=QuickActionExtraction  # Schema for each item
    ) as stream:
        for event in stream:
            if event.type == "response.output_text.delta":
                # Stream delta events to UI
                yield event.delta
            elif event.type == "response.completed":
                # Final parsed object available
                final_response = stream.get_final_response()
                yield {"complete": True, "data": final_response.output_parsed}
```

---

## 8. Complete Workflow Example

```python
class MeetingProcessorWorkflow:
    def __init__(self):
        self.orchestrator = MeetingOrchestratorService(client)
        self.response_svc = StructuredResponseService(client)
        self.data_svc = DataPipelineService(client)
    
    async def process_meeting_complete(self, 
                                      audio_file_path: str,
                                      meeting_date: str) -> dict:
        """End-to-end meeting processing"""
        
        # Step 1: Prepare context
        context = await self.data_svc.prepare_meeting_context(audio_file_path)
        transcript = context["transcript"]
        
        # Step 2: Process meeting with orchestrator
        summary = await self.orchestrator.process_meeting(
            transcript=transcript,
            meeting_id=f"meeting_{meeting_date}",
            quick_extraction=True
        )
        
        # Step 3: Extract supplementary details
        actions = await self.response_svc.extract(
            text=transcript,
            response_type=ResponseType.ACTION_EXTRACTION,
            context={"meeting_summary": summary}
        )
        
        # Step 4: Compile final result
        final_result = {
            "meeting_summary": summary,
            "action_items_detailed": actions["data"],
            "metadata": {
                "processed_at": datetime.now().isoformat(),
                "model": "gpt-5-nano-2025-08-07",
                "tokens_used": {
                    "summary": summary.usage,
                    "actions": actions["usage"]
                }
            }
        }
        
        return final_result
```

---

## 9. Best Practices Checklist

### Schema Design
- [ ] All fields are `required` (use `Optional[str]` for nullables)
- [ ] `additionalProperties: false` on all objects
- [ ] Clear descriptions for each field
- [ ] Use enums for constrained values
- [ ] Test schema with sample data before deployment

### API Usage
- [ ] Use Responses API for reliable structured output
- [ ] Use Chat Completions for conversational follow-ups
- [ ] Batch requests when processing multiple items
- [ ] Implement retry logic with exponential backoff
- [ ] Monitor token usage and costs

### Service Architecture
- [ ] Separate concerns: orchestration, response handling, data pipeline
- [ ] Cache schemas and prompts
- [ ] Implement comprehensive error handling
- [ ] Log all LLM calls for debugging
- [ ] Use streaming for real-time UX

### Production Considerations
- [ ] Implement request rate limiting
- [ ] Add monitoring/alerting for API failures
- [ ] Test refusal scenarios
- [ ] Version your schemas
- [ ] Use async/await throughout

---

## 10. Key Limitations & Workarounds

| Challenge | Solution |
|-----------|----------|
| **Long transcripts** | Segment into 2000-word chunks, process in parallel, synthesize |
| **Model refusals** | Rephrase requests, anonymize sensitive data, retry with context |
| **Token limits** | Use embeddings + RAG for context retrieval instead of full text |
| **Cost scaling** | Use gpt-5-nano (cheaper) for extraction, reserve gpt-5 for reasoning |
| **Latency** | Batch requests, use streaming for UI feedback, process segments in parallel |

---

## References

- **OpenAI Structured Outputs**: https://platform.openai.com/docs/guides/structured-outputs
- **Responses API**: https://platform.openai.com/docs/api-reference/responses
- **Agentic Design Patterns**: https://www.philschmid.de/agentic-pattern
- **OpenAI Agent Guide**: https://platform.openai.com/docs/guides/agents
