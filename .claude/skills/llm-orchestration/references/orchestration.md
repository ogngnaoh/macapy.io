# Orchestration Patterns

## Table of Contents
1. [Multi-Step Pipelines](#multi-step-pipelines)
2. [Chain-of-Thought Reasoning](#chain-of-thought-reasoning)
3. [Multi-Agent Verification](#multi-agent-verification)
4. [Streaming Patterns](#streaming-patterns)

---

## Multi-Step Pipelines

### Sequential Processing Pattern

```python
from dataclasses import dataclass
from typing import List, Optional, Callable, Any
import asyncio

@dataclass
class PipelineStep:
    """Single step in a processing pipeline"""
    name: str
    processor: Callable
    required: bool = True
    timeout_seconds: int = 30

@dataclass
class PipelineContext:
    """Shared context across pipeline steps"""
    meeting_id: str
    input_data: Any
    intermediate_results: dict = None
    errors: List[str] = None

    def __post_init__(self):
        if self.intermediate_results is None:
            self.intermediate_results = {}
        if self.errors is None:
            self.errors = []

class ProcessingPipeline:
    """Execute sequential steps with shared context"""

    def __init__(self, steps: List[PipelineStep]):
        self.steps = steps

    async def execute(self, ctx: PipelineContext) -> PipelineContext:
        for step in self.steps:
            try:
                result = await asyncio.wait_for(
                    step.processor(ctx),
                    timeout=step.timeout_seconds
                )
                ctx.intermediate_results[step.name] = result
            except asyncio.TimeoutError:
                ctx.errors.append(f"{step.name}: timeout after {step.timeout_seconds}s")
                if step.required:
                    raise
            except Exception as e:
                ctx.errors.append(f"{step.name}: {str(e)}")
                if step.required:
                    raise
        return ctx
```

### Parallel Processing Pattern

```python
async def process_segments_parallel(
    segments: List[str],
    processor: Callable,
    max_concurrent: int = 5
) -> List[dict]:
    """Process multiple segments concurrently with rate limiting"""
    semaphore = asyncio.Semaphore(max_concurrent)

    async def process_with_limit(segment: str, index: int) -> dict:
        async with semaphore:
            result = await processor(segment)
            return {"index": index, "result": result}

    tasks = [
        process_with_limit(seg, i)
        for i, seg in enumerate(segments)
    ]

    results = await asyncio.gather(*tasks, return_exceptions=True)

    # Sort by original index, filter errors
    valid_results = [r for r in results if not isinstance(r, Exception)]
    return sorted(valid_results, key=lambda x: x["index"])
```

### Map-Reduce Pattern for Long Transcripts

```python
from openai import OpenAI

class MapReduceProcessor:
    """Map-reduce pattern for processing long transcripts"""

    def __init__(self, client: OpenAI, model: str = "gpt-5-nano-2025-08-07"):
        self.client = client
        self.model = model

    async def process(
        self,
        transcript: str,
        chunk_size: int = 2000
    ) -> dict:
        # Map phase: extract from each chunk
        chunks = self._split_transcript(transcript, chunk_size)
        extractions = await self._map_phase(chunks)

        # Reduce phase: synthesize results
        return await self._reduce_phase(extractions)

    def _split_transcript(self, text: str, chunk_size: int) -> List[str]:
        words = text.split()
        return [
            ' '.join(words[i:i+chunk_size])
            for i in range(0, len(words), chunk_size)
        ]

    async def _map_phase(self, chunks: List[str]) -> List[dict]:
        """Extract key information from each chunk"""
        extractions = []
        for i, chunk in enumerate(chunks):
            response = self.client.responses.parse(
                model=self.model,
                input=[
                    {"role": "system", "content": "Extract action items, decisions, and key topics."},
                    {"role": "user", "content": f"Chunk {i+1}/{len(chunks)}:\n\n{chunk}"}
                ],
                text_format=SegmentExtraction
            )
            extractions.append(response.output_parsed.dict())
        return extractions

    async def _reduce_phase(self, extractions: List[dict]) -> dict:
        """Synthesize extractions into final summary"""
        combined = "\n\n".join(str(e) for e in extractions)
        response = self.client.responses.parse(
            model=self.model,
            input=[
                {"role": "system", "content": "Synthesize and deduplicate these extractions."},
                {"role": "user", "content": combined}
            ],
            text_format=MeetingSummary
        )
        return response.output_parsed.dict()
```

---

## Chain-of-Thought Reasoning

### Explicit Reasoning Schema

```python
from pydantic import BaseModel, Field
from typing import List, Optional

class ThinkingStep(BaseModel):
    step_number: int
    observation: str = Field(..., description="What I notice in the transcript")
    reasoning: str = Field(..., description="Why this is significant")
    conclusion: Optional[str] = Field(None, description="Interim conclusion if any")

class ReasonedAnalysis(BaseModel):
    """Output with explicit chain-of-thought"""
    thinking: List[ThinkingStep] = Field(..., description="Step-by-step reasoning")
    final_answer: str = Field(..., description="Synthesized conclusion")
    confidence: float = Field(..., ge=0.0, le=1.0)
    caveats: List[str] = Field(default_factory=list)
```

### Reasoning Pipeline

```python
class ReasoningPipeline:
    """Force explicit reasoning before conclusions"""

    def __init__(self, client: OpenAI):
        self.client = client

    async def analyze_with_reasoning(
        self,
        query: str,
        context: str
    ) -> ReasonedAnalysis:
        response = self.client.responses.parse(
            model="gpt-5-nano-2025-08-07",
            input=[
                {
                    "role": "system",
                    "content": """You are an analytical assistant. For every query:
1. List your observations from the context
2. Explain your reasoning for each observation
3. Draw interim conclusions
4. Synthesize into a final answer
5. Rate your confidence and note any caveats

Be explicit about your thinking process."""
                },
                {"role": "user", "content": f"Context:\n{context}\n\nQuery: {query}"}
            ],
            text_format=ReasonedAnalysis
        )
        return response.output_parsed
```

### Self-Critique Pattern

```python
class SelfCritiqueAnalysis(BaseModel):
    initial_answer: str
    critique: str = Field(..., description="Potential issues with initial answer")
    revised_answer: str = Field(..., description="Improved answer after critique")
    changes_made: List[str] = Field(..., description="What was changed and why")

async def analyze_with_self_critique(
    client: OpenAI,
    query: str,
    context: str
) -> SelfCritiqueAnalysis:
    """Generate answer, critique it, then revise"""
    return client.responses.parse(
        model="gpt-5-nano-2025-08-07",
        input=[
            {
                "role": "system",
                "content": """Analyze the query in three phases:
1. Provide an initial answer
2. Critically examine your answer for errors, omissions, or unclear points
3. Provide a revised, improved answer
Be thorough in your self-critique."""
            },
            {"role": "user", "content": f"Context:\n{context}\n\nQuery: {query}"}
        ],
        text_format=SelfCritiqueAnalysis
    ).output_parsed
```

---

## Multi-Agent Verification

### Extractor-Verifier Pattern

```python
from pydantic import BaseModel
from typing import List, Optional

class ExtractionResult(BaseModel):
    items: List[str]
    source_quotes: List[str]

class VerificationResult(BaseModel):
    item: str
    is_valid: bool
    confidence: float = Field(ge=0, le=1)
    reasoning: str
    correction: Optional[str] = None

class ExtractorVerifierPipeline:
    """Two-agent pattern: extract then verify"""

    def __init__(self, client: OpenAI):
        self.client = client

    async def extract_and_verify(
        self,
        transcript: str,
        extraction_type: str = "action_items"
    ) -> List[dict]:
        # Agent 1: Extract
        extractions = await self._extract(transcript, extraction_type)

        # Agent 2: Verify each extraction
        verified = []
        for item, quote in zip(extractions.items, extractions.source_quotes):
            verification = await self._verify(item, quote, transcript)
            if verification.is_valid:
                verified.append({
                    "item": verification.correction or item,
                    "confidence": verification.confidence,
                    "source": quote
                })

        return verified

    async def _extract(self, transcript: str, extraction_type: str) -> ExtractionResult:
        return self.client.responses.parse(
            model="gpt-5-nano-2025-08-07",
            input=[
                {"role": "system", "content": f"Extract all {extraction_type}. Include source quotes."},
                {"role": "user", "content": transcript}
            ],
            text_format=ExtractionResult
        ).output_parsed

    async def _verify(
        self,
        item: str,
        source_quote: str,
        full_transcript: str
    ) -> VerificationResult:
        return self.client.responses.parse(
            model="gpt-5-nano-2025-08-07",
            input=[
                {
                    "role": "system",
                    "content": """Verify this extraction:
1. Is it actually stated in the transcript?
2. Is the interpretation accurate?
3. Suggest corrections if needed."""
                },
                {
                    "role": "user",
                    "content": f"Item: {item}\nSource: {source_quote}\n\nFull transcript:\n{full_transcript}"
                }
            ],
            text_format=VerificationResult
        ).output_parsed
```

### Consensus Pattern (Multiple Extractors)

```python
from collections import Counter

async def extract_with_consensus(
    client: OpenAI,
    transcript: str,
    num_passes: int = 3
) -> List[dict]:
    """Run extraction multiple times, keep items with consensus"""
    all_items = []

    # Multiple extraction passes with temperature variation
    for i in range(num_passes):
        response = client.responses.parse(
            model="gpt-5-nano-2025-08-07",
            input=[
                {"role": "system", "content": "Extract all action items."},
                {"role": "user", "content": transcript}
            ],
            text_format=ActionItemList,
            temperature=0.3 + (i * 0.2)  # Vary temperature
        )
        all_items.extend(response.output_parsed.items)

    # Normalize and count occurrences
    normalized = [item.lower().strip() for item in all_items]
    counts = Counter(normalized)

    # Keep items that appear in majority of passes
    threshold = num_passes // 2 + 1
    consensus_items = [
        item for item, count in counts.items()
        if count >= threshold
    ]

    return consensus_items
```

---

## Streaming Patterns

### SSE Streaming for Real-Time UI

```python
from fastapi import FastAPI
from fastapi.responses import StreamingResponse
import json

app = FastAPI()

async def stream_analysis(transcript: str):
    """Generator for SSE streaming"""
    client = OpenAI()

    # Stream thinking steps
    yield f"data: {json.dumps({'type': 'thinking', 'content': 'Analyzing transcript...'})}\n\n"

    # Stream extraction results incrementally
    for chunk in client.responses.parse(
        model="gpt-5-nano-2025-08-07",
        input=[
            {"role": "system", "content": "Extract meeting information."},
            {"role": "user", "content": transcript}
        ],
        text_format=MeetingSummary,
        stream=True
    ):
        if chunk.output_parsed:
            yield f"data: {json.dumps({'type': 'partial', 'content': chunk.output_parsed.dict()})}\n\n"

    yield f"data: {json.dumps({'type': 'complete'})}\n\n"

@app.post("/api/ai/analyze")
async def analyze_meeting(transcript: str):
    return StreamingResponse(
        stream_analysis(transcript),
        media_type="text/event-stream"
    )
```

### Chunked Progress Updates

```python
async def process_with_progress(
    transcript: str,
    on_progress: Callable[[str, float], None]
) -> MeetingSummary:
    """Report progress during long processing"""

    # Step 1: Normalize (20%)
    on_progress("Normalizing transcript...", 0.0)
    normalized = await normalize_transcript(transcript)
    on_progress("Transcript normalized", 0.2)

    # Step 2: Segment (30%)
    on_progress("Segmenting transcript...", 0.2)
    segments = segment_transcript(normalized)
    on_progress(f"Created {len(segments)} segments", 0.3)

    # Step 3: Extract per segment (30-80%)
    extractions = []
    for i, segment in enumerate(segments):
        progress = 0.3 + (0.5 * (i / len(segments)))
        on_progress(f"Processing segment {i+1}/{len(segments)}", progress)
        extraction = await extract_from_segment(segment)
        extractions.append(extraction)

    # Step 4: Synthesize (80-100%)
    on_progress("Synthesizing final summary...", 0.8)
    summary = await synthesize_summary(extractions)
    on_progress("Complete", 1.0)

    return summary
```

---

## Pipeline Configuration

### Configurable Pipeline Factory

```python
from enum import Enum

class ProcessingMode(str, Enum):
    QUICK = "quick"      # Fast, minimal processing
    STANDARD = "standard" # Balanced
    THOROUGH = "thorough" # Maximum accuracy

def create_pipeline(mode: ProcessingMode) -> ProcessingPipeline:
    """Factory for different processing modes"""

    if mode == ProcessingMode.QUICK:
        return ProcessingPipeline([
            PipelineStep("extract", quick_extract, timeout_seconds=10),
        ])

    elif mode == ProcessingMode.STANDARD:
        return ProcessingPipeline([
            PipelineStep("normalize", normalize_transcript, timeout_seconds=15),
            PipelineStep("extract", standard_extract, timeout_seconds=20),
            PipelineStep("format", format_output, timeout_seconds=5),
        ])

    else:  # THOROUGH
        return ProcessingPipeline([
            PipelineStep("normalize", normalize_transcript, timeout_seconds=15),
            PipelineStep("segment", segment_transcript, timeout_seconds=10),
            PipelineStep("extract", extract_with_verification, timeout_seconds=60),
            PipelineStep("synthesize", synthesize_with_reasoning, timeout_seconds=30),
            PipelineStep("verify", final_verification, timeout_seconds=20),
        ])
```
