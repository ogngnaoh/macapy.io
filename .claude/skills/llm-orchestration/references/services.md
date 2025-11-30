# Service Layer Implementation

## Table of Contents
1. [MeetingOrchestratorService](#meetingorchestratorservice)
2. [StructuredResponseService](#structuredresponseservice)
3. [DataPipelineService](#datapipelineservice)

---

## MeetingOrchestratorService

Manages complete meeting processing pipeline.

```python
from dataclasses import dataclass
from typing import List, Optional
from openai import OpenAI

@dataclass
class ProcessingContext:
    """State across multiple LLM calls"""
    meeting_id: str
    transcript: str
    intermediate_extractions: dict = None
    conversation_history: List[dict] = None

    def __post_init__(self):
        if self.conversation_history is None:
            self.conversation_history = []

class MeetingOrchestratorService:
    def __init__(self, client: OpenAI, model: str = "gpt-5-nano-2025-08-07"):
        self.client = client
        self.model = model

    async def process_meeting(
        self,
        transcript: str,
        meeting_id: str,
        quick_extraction: bool = False
    ) -> dict:
        """
        Complete pipeline:
        1. Normalize transcript
        2. Segment if long
        3. Extract from each segment (parallel)
        4. Synthesize final summary
        """
        ctx = ProcessingContext(meeting_id=meeting_id, transcript=transcript)

        # Step 1: Normalize
        ctx = await self._normalize_transcript(ctx)

        # Step 2: Segment
        segments = await self._segment_transcript(ctx)

        # Step 3: Extract per segment
        segment_summaries = await self._process_segments(segments, ctx)

        # Step 4: Synthesize
        return await self._synthesize_summary(segment_summaries, ctx)

    async def _normalize_transcript(self, ctx: ProcessingContext) -> ProcessingContext:
        response = self.client.responses.parse(
            model=self.model,
            input=[
                {"role": "system", "content": "Clean speech-to-text errors, identify speakers."},
                {"role": "user", "content": f"Normalize:\n\n{ctx.transcript}"}
            ],
            text_format=NormalizedTranscript
        )
        ctx.transcript = response.output_parsed.normalized_text
        return ctx

    async def _segment_transcript(self, ctx: ProcessingContext) -> List[str]:
        """Split at ~2000 words per segment"""
        words = ctx.transcript.split()
        chunk_size = 2000
        return [
            ' '.join(words[i:i+chunk_size])
            for i in range(0, len(words), chunk_size)
        ]

    async def _process_segments(
        self,
        segments: List[str],
        ctx: ProcessingContext
    ) -> List[dict]:
        """Process each segment (can be parallelized with asyncio.gather)"""
        summaries = []
        for i, segment in enumerate(segments):
            response = self.client.responses.parse(
                model=self.model,
                input=[
                    {"role": "system", "content": "Extract action items, decisions, topics."},
                    {"role": "user", "content": f"Segment {i+1}/{len(segments)}:\n\n{segment}"}
                ],
                text_format=SegmentExtraction
            )
            summaries.append(response.output_parsed.dict())
        return summaries

    async def _synthesize_summary(
        self,
        segment_summaries: List[dict],
        ctx: ProcessingContext
    ) -> MeetingSummary:
        combined = "\n\n".join(str(s) for s in segment_summaries)
        response = self.client.responses.parse(
            model=self.model,
            input=[
                {"role": "system", "content": "Synthesize segment summaries. Deduplicate, merge related items."},
                {"role": "user", "content": f"Synthesize:\n\n{combined}"}
            ],
            text_format=MeetingSummary
        )
        return response.output_parsed
```

---

## StructuredResponseService

Schema registry and extraction with validation.

```python
from enum import Enum

class ResponseType(str, Enum):
    MEETING_SUMMARY = "meeting_summary"
    ACTION_EXTRACTION = "action_extraction"
    DECISION_LOG = "decision_log"
    QUICK_FEEDBACK = "quick_feedback"

class StructuredResponseService:
    """Centralized schema management and extraction"""

    SCHEMAS = {
        ResponseType.MEETING_SUMMARY: MeetingSummary,
        ResponseType.ACTION_EXTRACTION: ActionItem,
        ResponseType.DECISION_LOG: Decision,
        ResponseType.QUICK_FEEDBACK: QuickActionExtraction,
    }

    PROMPTS = {
        ResponseType.MEETING_SUMMARY:
            "Extract and structure all meeting information.",
        ResponseType.ACTION_EXTRACTION:
            "Identify all action items with owners and deadlines.",
        ResponseType.DECISION_LOG:
            "Document all key decisions with context.",
        ResponseType.QUICK_FEEDBACK:
            "Quickly identify urgent action items.",
    }

    def __init__(self, client: OpenAI):
        self.client = client

    async def extract(
        self,
        text: str,
        response_type: ResponseType,
        system_prompt: str = None,
        context: dict = None
    ) -> dict:
        schema_class = self.SCHEMAS[response_type]
        prompt = system_prompt or self.PROMPTS[response_type]

        try:
            response = self.client.responses.parse(
                model="gpt-5-nano-2025-08-07",
                input=[
                    {"role": "system", "content": prompt},
                    {"role": "user", "content": text}
                ],
                text_format=schema_class
            )

            if response.refusal:
                return {"status": "refused", "reason": response.refusal}

            return {
                "status": "success",
                "data": response.output_parsed.dict(),
                "usage": {
                    "input_tokens": response.usage.prompt_tokens,
                    "output_tokens": response.usage.completion_tokens
                }
            }
        except Exception as e:
            return {"status": "error", "error": str(e)}
```

---

## DataPipelineService

Audio processing, chunking, and context retrieval.

```python
from typing import List, Tuple
import numpy as np

class DataPipelineService:
    """Audio → Transcript → Chunks → Embeddings"""

    def __init__(self, client: OpenAI, db_service=None):
        self.client = client
        self.db_service = db_service

    async def prepare_meeting_context(self, audio_path: str) -> dict:
        transcript = await self._transcribe_audio(audio_path)
        chunks = self._create_semantic_chunks(transcript)
        embeddings = await self._embed_chunks(chunks)

        if self.db_service:
            await self.db_service.store_meeting_chunks(
                transcript, chunks, embeddings
            )

        return {"transcript": transcript, "chunks": chunks, "embeddings": embeddings}

    async def _transcribe_audio(self, audio_path: str) -> str:
        with open(audio_path, "rb") as f:
            transcript = self.client.audio.transcriptions.create(
                model="whisper-1",
                file=f,
                language="en"
            )
        return transcript.text

    def _create_semantic_chunks(self, transcript: str) -> List[dict]:
        """Split at ~500 words per chunk"""
        chunks = []
        current_chunk = ""
        chunk_id = 0

        for sentence in transcript.split(". "):
            current_chunk += sentence + ". "
            if len(current_chunk.split()) > 500:
                chunks.append({
                    "id": f"chunk_{chunk_id}",
                    "text": current_chunk,
                    "word_count": len(current_chunk.split())
                })
                current_chunk = ""
                chunk_id += 1

        if current_chunk.strip():
            chunks.append({
                "id": f"chunk_{chunk_id}",
                "text": current_chunk,
                "word_count": len(current_chunk.split())
            })

        return chunks

    async def _embed_chunks(self, chunks: List[dict]) -> List[List[float]]:
        texts = [c["text"] for c in chunks]
        response = self.client.embeddings.create(
            model="text-embedding-3-small",
            input=texts
        )
        return [item.embedding for item in response.data]

    async def retrieve_context(
        self,
        query: str,
        chunks: List[dict],
        embeddings: List[List[float]],
        top_k: int = 3
    ) -> str:
        """RAG-style retrieval: cosine similarity search"""
        query_emb = self.client.embeddings.create(
            model="text-embedding-3-small",
            input=query
        ).data[0].embedding

        # Cosine similarity
        similarities = [
            np.dot(query_emb, emb) / (np.linalg.norm(query_emb) * np.linalg.norm(emb))
            for emb in embeddings
        ]

        top_indices = sorted(
            range(len(similarities)),
            key=lambda i: similarities[i],
            reverse=True
        )[:top_k]

        return "\n\n".join(chunks[i]["text"] for i in top_indices)
```
