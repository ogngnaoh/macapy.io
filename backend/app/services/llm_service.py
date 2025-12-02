"""
LLM Service for macapy.io
Uses OpenAI Responses API for reasoning, summaries, and suggestions.

Migrated from Chat Completions API to Responses API for GPT-5 nano support.
Includes structured outputs using Pydantic schemas.
"""

import openai
from openai import RateLimitError, APIError
from typing import AsyncGenerator, List, Optional
import json
import logging
import tiktoken
from app.config import settings
from app.schemas.ai import (
    MeetingSummary, QuestionDetection, SuggestionResponse,
    RecapOutput, ErrorCode, EnhancedMeetingSummary, EnhancedSuggestionResponse,
    QueryResponse
)

logger = logging.getLogger(__name__)


# =============================================================================
# Enhanced System Prompts for Context-Aware Operations
# =============================================================================

SYSTEM_PROMPTS = {
    "summary": """You are a meeting assistant for macapy.io.

Your task:
1. Summarize key points from the recent conversation
2. Identify action items with owners if mentioned
3. Note important decisions made
4. Reference relevant uploaded documents when applicable

Context provided:
- Meeting metadata (title, platform, duration)
- Recent transcripts with speaker attribution
- Previously generated summaries
- Relevant document excerpts

Output guidelines:
- Use bullet points for clarity
- Attribute actions to specific people when known
- Reference documents by filename when relevant (e.g., "[From: resume.pdf]")
- Keep summaries to 3-5 key points
- Highlight any unanswered questions""",

    "suggestion": """You are a real-time meeting assistant helping the user respond to questions.

Your task:
1. Analyze the detected question in context
2. Review uploaded documents for relevant background
3. Generate 3 distinct, natural response options

Guidelines:
- One suggestion: brief and confident response
- One suggestion: more detailed with examples from documents if available
- One suggestion: asks for clarification or redirects appropriately
- Reference document details when helpful (e.g., "[From: resume.pdf]")
- Keep responses conversational and natural""",

    "query": """You are macapy.io, an AI meeting assistant providing real-time support.

Capabilities:
- Answer questions about the current meeting
- Reference uploaded documents for context
- Provide summaries and action items
- Offer follow-up suggestions

Guidelines:
- Be concise and actionable
- Cite document sources: "[From: filename.pdf]"
- If information isn't in context, clearly say so
- Suggest follow-up questions when appropriate
- Maintain professional but conversational tone""",

    "recap": """You are a meeting assistant providing quick recaps.

Your task:
- Summarize the key moments from the recent conversation
- Highlight any questions asked or decisions made
- Note any action items mentioned

Keep the recap brief (2-3 bullet points) and focused on what's most important."""
}


# =============================================================================
# LLM Exception Classes
# =============================================================================

class LLMError(Exception):
    """Base LLM error"""
    def __init__(self, message: str, code: ErrorCode, recoverable: bool = True):
        self.message = message
        self.code = code
        self.recoverable = recoverable
        super().__init__(message)


class LLMRefusalError(LLMError):
    """Model refused to respond"""
    def __init__(self, refusal_reason: str):
        super().__init__(
            message=f"Model refused: {refusal_reason}",
            code=ErrorCode.REFUSAL,
            recoverable=False
        )


class LLMRateLimitError(LLMError):
    """Rate limit exceeded"""
    def __init__(self, retry_after: int = 60):
        self.retry_after = retry_after
        super().__init__(
            message=f"Rate limit exceeded. Retry after {retry_after}s",
            code=ErrorCode.RATE_LIMIT,
            recoverable=True
        )


class LLMService:
    """
    Service for LLM-based reasoning using OpenAI Responses API.

    Features:
    - Summary generation (streaming and non-streaming)
    - Question detection for response suggestions
    - Suggestion generation with JSON output
    - User query answering with streaming
    - Token counting and context management
    """

    def __init__(self):
        self.client = openai.AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
        self.model = settings.GPT_MODEL  # "gpt-5-nano"
        self.max_input_tokens = 272_000
        self.max_output_tokens = 128_000

        # Use cl100k_base encoding (GPT-4/GPT-3.5 compatible) as approximation
        try:
            self.encoding = tiktoken.get_encoding("cl100k_base")
        except Exception as e:
            logger.warning(f"Failed to load tiktoken encoding: {e}")
            self.encoding = None

    def _extract_text_from_response(self, response) -> str:
        """
        Extract text content from Responses API response.

        GPT-5 nano response format (with reasoning):
        {
            "output": [
                {"type": "reasoning", ...},  # First: reasoning item
                {
                    "type": "message",       # Second: message with text
                    "content": [
                        {"type": "output_text", "text": "..."}
                    ]
                }
            ]
        }

        Implements multiple fallback strategies for robustness.
        """
        try:
            # Enhanced logging: Log full response structure
            logger.debug(f"_extract_text: response type={type(response).__name__}")
            response_attrs = [a for a in dir(response) if not a.startswith('_') and not callable(getattr(response, a, None))]
            logger.debug(f"_extract_text: response attributes={response_attrs}")

            # Strategy 1: Check for output_text attribute (OpenAI Responses API direct access)
            if hasattr(response, 'output_text') and response.output_text:
                logger.info(f"_extract_text: using Strategy 1 (response.output_text), length={len(response.output_text)}")
                return response.output_text

            # Strategy 2: Check for direct text attribute (fallback)
            if hasattr(response, 'text') and response.text:
                logger.info(f"_extract_text: using Strategy 2 (response.text), length={len(response.text)}")
                return response.text

            # Strategy 3: Check output array
            if not response.output:
                logger.warning("_extract_text: response.output is empty/None")
                return ""

            # Log each output item in detail for debugging
            for i, item in enumerate(response.output):
                item_attrs = {}
                for attr in ['type', 'role', 'status', 'content', 'text']:
                    if hasattr(item, attr):
                        val = getattr(item, attr)
                        if attr == 'content' and val:
                            item_attrs[attr] = f"[{len(val)} items]" if isinstance(val, list) else type(val).__name__
                        else:
                            item_attrs[attr] = str(val)[:100] if val else None
                logger.debug(f"_extract_text: output[{i}] = {item_attrs}")

            # Strategy 3: Standard message.content.output_text structure
            for item in response.output:
                if hasattr(item, 'type') and item.type == "message":
                    if hasattr(item, 'content') and item.content:
                        for content_part in item.content:
                            # Check for output_text type
                            if hasattr(content_part, 'type') and content_part.type == "output_text":
                                if hasattr(content_part, 'text') and content_part.text:
                                    logger.info(f"_extract_text: using Strategy 3 (message.content.output_text), length={len(content_part.text)}")
                                    return content_part.text
                            # Fallback: direct text attribute on content part
                            elif hasattr(content_part, 'text') and content_part.text:
                                logger.info(f"_extract_text: using Strategy 3b (content_part.text), length={len(content_part.text)}")
                                return content_part.text

            # Strategy 4: Search all output items for any text-like content
            for item in response.output:
                # Check for text directly on item
                if hasattr(item, 'text') and item.text:
                    logger.info(f"_extract_text: using Strategy 4 (item.text), length={len(item.text)}")
                    return item.text
                # Check content array if it exists
                if hasattr(item, 'content') and item.content:
                    for content_part in item.content:
                        if hasattr(content_part, 'text') and content_part.text:
                            logger.info(f"_extract_text: using Strategy 4b (any content.text), length={len(content_part.text)}")
                            return content_part.text

            logger.warning("_extract_text: all extraction strategies failed, no text found")
            # Log raw response for debugging
            try:
                import json
                if hasattr(response, 'model_dump'):
                    logger.debug(f"_extract_text: raw response dump: {json.dumps(response.model_dump(), default=str)[:1000]}")
            except Exception:
                pass
            return ""
        except (AttributeError, IndexError) as e:
            logger.error(f"Error extracting text from response: {e}", exc_info=True)
            return ""

    async def generate_summary(self, transcript_text: str) -> str:
        """
        Generates a concise summary of the provided transcript segment.

        Args:
            transcript_text: The transcript text to summarize

        Returns:
            Summary string, or empty string on failure
        """
        if not transcript_text.strip():
            logger.debug("generate_summary: empty transcript, returning empty string")
            return ""

        prompt = f"""Summarize the following conversation segment.
Focus on: key decisions, action items, and important questions raised.
Keep it concise (under 3 bullet points).

Transcript:
{transcript_text}"""

        logger.info(f"generate_summary: calling Responses API with model={self.model}, prompt_len={len(prompt)}")

        try:
            response = await self.client.responses.create(
                model=self.model,
                instructions="You are a helpful meeting assistant. Always provide a complete response with your summary.",
                input=prompt,
                max_output_tokens=500,  # Increased for GPT-5 nano reasoning overhead
                reasoning={"effort": "low"},  # Enable reasoning but with low effort for summaries
            )

            logger.debug(f"generate_summary: response.status={getattr(response, 'status', 'N/A')}, "
                        f"output_count={len(response.output) if response.output else 0}")

            result = self._extract_text_from_response(response).strip()

            if result:
                logger.info(f"generate_summary: success, result_len={len(result)}")
            else:
                logger.warning("generate_summary: extracted text is empty")

            return result

        except RateLimitError as e:
            logger.error(f"generate_summary: rate limit error - {e}")
            raise LLMRateLimitError(retry_after=getattr(e, 'retry_after', 60))
        except APIError as e:
            logger.error(f"generate_summary: API error - {type(e).__name__}: {e}")
            raise LLMError(message=str(e), code=ErrorCode.MODEL_ERROR, recoverable=True)
        except Exception as e:
            logger.error(f"generate_summary: unexpected error - {type(e).__name__}: {e}", exc_info=True)
            return ""

    async def generate_summary_stream(
        self,
        transcript_text: str,
        reasoning_effort: str = "low"
    ) -> AsyncGenerator[str, None]:
        """
        Stream summary generation for lower perceived latency.

        Args:
            transcript_text: The transcript text to summarize
            reasoning_effort: Reasoning effort level (low/medium/high)

        Yields:
            Text chunks as they are generated
        """
        if not transcript_text.strip():
            return

        prompt = f"""Summarize the following conversation segment.
Focus on: key decisions, action items, and important questions raised.
Keep it concise (under 3 bullet points).

Transcript:
{transcript_text}"""

        try:
            response = await self.client.responses.create(
                model=self.model,
                instructions="You are a helpful meeting assistant.",
                input=prompt,
                max_output_tokens=500,
                stream=True
            )

            async for event in response:
                # Handle streaming events from Responses API
                if hasattr(event, 'type'):
                    if event.type == "response.output_text.delta":
                        if hasattr(event, 'delta') and event.delta:
                            yield event.delta
                    elif event.type == "response.text.delta":
                        # Alternative event type
                        if hasattr(event, 'delta') and event.delta:
                            yield event.delta
                elif hasattr(event, 'delta') and event.delta:
                    yield event.delta
        except Exception as e:
            logger.error(f"Error streaming summary: {e}", exc_info=True)

    async def detect_question(self, text_segment: str) -> bool:
        """
        Determines if the text segment contains a question directed at the user.

        Args:
            text_segment: Text to analyze for questions

        Returns:
            True if a question requiring response is detected
        """
        if "?" not in text_segment:
            return False

        prompt = f"""Analyze the following text segment from a meeting.
Does it contain a question directed at the participant that requires a response?
Reply with only "YES" or "NO".

Text:
{text_segment}"""

        try:
            response = await self.client.responses.create(
                model=self.model,
                input=prompt,
                max_output_tokens=200  # Minimum is 16, increased for reasoning overhead
            )
            result_text = self._extract_text_from_response(response)
            return "YES" in result_text.upper()
        except Exception as e:
            logger.error(f"Error detecting question: {e}", exc_info=True)
            return False

    async def generate_suggestion(
        self,
        question: str,
        transcript_context: str,
        document_context: List[str]
    ) -> List[str]:
        """
        Generates response suggestions based on question and context.

        Args:
            question: The detected question to respond to
            transcript_context: Recent conversation transcript
            document_context: Relevant document chunks

        Returns:
            List of suggested responses (typically 3)
        """
        context_str = "\n\n".join(document_context)

        prompt = f"""User's Background / Context (from documents):
{context_str}

Recent Conversation:
{transcript_context}

Question Detected:
{question}

Provide 3 distinct, conversational response options for the user.
Keep them brief and natural.
Return as JSON with format: {{"suggestions": ["response1", "response2", "response3"]}}"""

        try:
            response = await self.client.responses.create(
                model=self.model,
                instructions="You are a helpful assistant providing real-time interview/meeting aid. Always respond with valid JSON.",
                input=prompt,
                text={"format": {"type": "json_object"}}
            )
            content = self._extract_text_from_response(response)

            if not content:
                return []

            data = json.loads(content)

            if "suggestions" in data:
                return data["suggestions"]
            elif "options" in data:
                return data["options"]

            # Fallback: try to find the first list value
            for key, value in data.items():
                if isinstance(value, list):
                    return value
            return []

        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse JSON from LLM response: {e}")
            return []
        except Exception as e:
            logger.error(f"Error generating suggestions: {e}", exc_info=True)
            return []

    async def answer_query_stream(
        self,
        question: str,
        transcript_context: str,
        summary_context: str,
        document_context: List[str],
        reasoning_effort: str = "medium"
    ) -> AsyncGenerator[str, None]:
        """
        Stream answer to user query with full context.

        Args:
            question: User's question
            transcript_context: Recent transcript text
            summary_context: Meeting summaries
            document_context: Relevant document chunks
            reasoning_effort: Reasoning effort level

        Yields:
            Answer text chunks as they are generated
        """
        doc_context_str = "\n\n".join(document_context)

        context = f"""Summaries:
{summary_context}

Recent Transcripts:
{transcript_context}

Relevant Documents:
{doc_context_str}"""

        logger.info(f"answer_query_stream: model={self.model}, question_len={len(question)}, "
                   f"context_len={len(context)}, docs={len(document_context)}")

        try:
            response = await self.client.responses.create(
                model=self.model,
                instructions="You are a helpful meeting assistant providing real-time support during meetings. Be concise and actionable. Always provide a complete response.",
                input=f"Context:\n{context}\n\nQuestion: {question}",
                max_output_tokens=1000,
                reasoning={"effort": "medium"},  # Enable reasoning for queries
                stream=True
            )

            chunk_count = 0
            total_chars = 0
            event_types_seen = set()
            first_event_logged = False

            async for event in response:
                event_type = getattr(event, 'type', None)
                event_types_seen.add(event_type)

                # Log first few events in detail for debugging
                if not first_event_logged or chunk_count < 3:
                    event_attrs = [a for a in dir(event) if not a.startswith('_') and not callable(getattr(event, a, None))]
                    logger.debug(f"answer_query_stream: event #{chunk_count} type={event_type}, attrs={event_attrs}")
                    first_event_logged = True

                # Helper function to extract and yield text
                def try_yield_text(text_value, source):
                    nonlocal chunk_count, total_chars
                    if text_value and isinstance(text_value, str):
                        chunk_count += 1
                        total_chars += len(text_value)
                        logger.debug(f"answer_query_stream: yielding from {source}, len={len(text_value)}")
                        return text_value
                    return None

                # Strategy 1: Check for delta as string directly on event
                delta = getattr(event, 'delta', None)
                if delta:
                    if isinstance(delta, str):
                        text = try_yield_text(delta, "delta (string)")
                        if text:
                            yield text
                            continue
                    # delta might be an object with text attribute
                    elif hasattr(delta, 'text'):
                        text = try_yield_text(delta.text, "delta.text")
                        if text:
                            yield text
                            continue
                    # delta might be an object with value attribute
                    elif hasattr(delta, 'value'):
                        text = try_yield_text(delta.value, "delta.value")
                        if text:
                            yield text
                            continue

                # Strategy 2: Check for specific Responses API event types
                if event_type in ("response.output_text.delta", "response.text.delta",
                                  "response.content_part.delta", "content_block_delta"):
                    # Try delta attribute
                    if hasattr(event, 'delta') and event.delta:
                        if isinstance(event.delta, str):
                            text = try_yield_text(event.delta, f"{event_type}.delta")
                            if text:
                                yield text
                                continue
                        elif hasattr(event.delta, 'text'):
                            text = try_yield_text(event.delta.text, f"{event_type}.delta.text")
                            if text:
                                yield text
                                continue

                # Strategy 3: Check for text attribute directly on event
                if hasattr(event, 'text') and event.text:
                    text = try_yield_text(event.text, "event.text")
                    if text:
                        yield text
                        continue

                # Strategy 4: Check for content attribute
                if hasattr(event, 'content') and event.content:
                    if isinstance(event.content, str):
                        text = try_yield_text(event.content, "event.content")
                        if text:
                            yield text
                            continue

                # Strategy 5: Check for output_text attribute
                if hasattr(event, 'output_text') and event.output_text:
                    text = try_yield_text(event.output_text, "event.output_text")
                    if text:
                        yield text
                        continue

            logger.info(f"answer_query_stream: completed, chunks={chunk_count}, total_chars={total_chars}, "
                       f"event_types={list(event_types_seen)}")

            if chunk_count == 0:
                logger.warning(f"answer_query_stream: no text chunks received! Event types seen: {list(event_types_seen)}")
                yield "No response generated. Please try again."

        except RateLimitError as e:
            logger.error(f"answer_query_stream: rate limit error - {e}")
            yield f"Rate limit exceeded. Please wait {getattr(e, 'retry_after', 60)} seconds."
        except APIError as e:
            logger.error(f"answer_query_stream: API error - {type(e).__name__}: {e}")
            yield f"API Error: {str(e)}"
        except Exception as e:
            logger.error(f"answer_query_stream: unexpected error - {type(e).__name__}: {e}", exc_info=True)
            yield f"Error generating response: {str(e)}"

    def count_tokens(self, text: str) -> int:
        """
        Count tokens in text using tiktoken.

        Args:
            text: Text to count tokens for

        Returns:
            Number of tokens
        """
        if not text:
            return 0
        if self.encoding:
            return len(self.encoding.encode(text))
        return len(text) // 4  # Fallback approximation

    def build_context_within_limit(
        self,
        transcripts: List[str],
        summaries: List[str],
        max_tokens: int = 200_000
    ) -> tuple[str, str]:
        """
        Build context that fits within token limit, prioritizing recent content.

        Args:
            transcripts: List of transcript texts (oldest to newest)
            summaries: List of summary texts
            max_tokens: Maximum token budget

        Returns:
            Tuple of (transcript_text, summary_text) within budget
        """
        # Always include all summaries (more valuable, smaller)
        summary_text = "\n\n".join(summaries)
        summary_tokens = self.count_tokens(summary_text)

        # Calculate remaining budget for transcripts
        remaining_tokens = max_tokens - summary_tokens - 5000  # Buffer

        # Build transcript from most recent, going backwards
        transcript_chunks = []
        current_tokens = 0

        for transcript in reversed(transcripts):
            chunk_tokens = self.count_tokens(transcript)
            if current_tokens + chunk_tokens > remaining_tokens:
                break
            transcript_chunks.insert(0, transcript)
            current_tokens += chunk_tokens

        transcript_text = "\n".join(transcript_chunks)
        return transcript_text, summary_text

    # =========================================================================
    # Structured Output Methods (using Pydantic schemas)
    # =========================================================================

    def _check_refusal(self, response) -> None:
        """Check if model refused and raise appropriate error"""
        if hasattr(response, 'refusal') and response.refusal:
            raise LLMRefusalError(response.refusal)

    def _get_summary_prompt(self) -> str:
        """Get system prompt for summary generation"""
        return """You are a meeting assistant that generates structured meeting summaries.
Extract key information from the transcript:
- summary: Brief 2-3 sentence overview
- key_points: Main discussion topics
- action_items: Tasks with owners/deadlines if mentioned
- decisions: Important decisions made
- follow_ups: Topics needing follow-up"""

    def _get_question_detection_prompt(self) -> str:
        """Get system prompt for question detection"""
        return """Analyze the text and determine if it contains a question directed at the meeting participant.
Return structured output with:
- is_question: true if a direct question requiring response exists
- question_text: the actual question if detected
- confidence: how confident you are (0.0 to 1.0)"""

    async def generate_summary_structured(
        self,
        transcript_text: str,
        reasoning_effort: str = "medium"
    ) -> MeetingSummary:
        """
        Generate meeting summary with structured Pydantic output.

        Args:
            transcript_text: The transcript text to summarize
            reasoning_effort: Reasoning effort level (low/medium/high)

        Returns:
            MeetingSummary structured object

        Raises:
            LLMRefusalError: If model refuses to respond
            LLMRateLimitError: If rate limit exceeded
            LLMError: For other errors
        """
        if not transcript_text.strip():
            return MeetingSummary(
                summary="No transcript content to summarize.",
                key_points=[]
            )

        try:
            response = await self.client.responses.parse(
                model=self.model,
                input=[
                    {"role": "system", "content": self._get_summary_prompt()},
                    {"role": "user", "content": f"Transcript:\n{transcript_text}"}
                ],
                text_format=MeetingSummary,
                reasoning={"effort": reasoning_effort}
            )

            self._check_refusal(response)
            return response.output_parsed

        except RateLimitError as e:
            retry_after = getattr(e, 'retry_after', 60)
            raise LLMRateLimitError(retry_after=retry_after)
        except LLMError:
            raise
        except Exception as e:
            logger.error(f"Error generating structured summary: {e}", exc_info=True)
            raise LLMError(
                message=str(e),
                code=ErrorCode.MODEL_ERROR,
                recoverable=True
            )

    async def detect_question_structured(
        self,
        text: str
    ) -> QuestionDetection:
        """
        Detect if text contains a question with structured output.

        Args:
            text: Text to analyze for questions

        Returns:
            QuestionDetection structured object
        """
        # Quick check for question mark
        if "?" not in text:
            return QuestionDetection(
                is_question=False,
                question_text=None,
                confidence=1.0
            )

        try:
            response = await self.client.responses.parse(
                model=self.model,
                input=[
                    {"role": "system", "content": self._get_question_detection_prompt()},
                    {"role": "user", "content": text}
                ],
                text_format=QuestionDetection
            )

            self._check_refusal(response)
            return response.output_parsed

        except RateLimitError as e:
            raise LLMRateLimitError(retry_after=getattr(e, 'retry_after', 60))
        except LLMError:
            raise
        except Exception as e:
            logger.error(f"Error detecting question: {e}", exc_info=True)
            # Return safe default on error
            return QuestionDetection(
                is_question=False,
                question_text=None,
                confidence=0.0
            )

    async def generate_suggestion_structured(
        self,
        question: str,
        transcript_context: str,
        document_context: List[str]
    ) -> SuggestionResponse:
        """
        Generate response suggestions with structured output.

        Args:
            question: The detected question to respond to
            transcript_context: Recent conversation transcript
            document_context: Relevant document chunks

        Returns:
            SuggestionResponse structured object
        """
        context_str = "\n\n".join(document_context) if document_context else ""
        has_context = bool(document_context)

        prompt = f"""User's Background / Context (from documents):
{context_str if context_str else "No document context available."}

Recent Conversation:
{transcript_context}

Question Detected:
{question}

Provide 3 distinct, conversational response options for the user.
Keep them brief and natural."""

        try:
            response = await self.client.responses.parse(
                model=self.model,
                input=[
                    {
                        "role": "system",
                        "content": "You are a helpful assistant providing real-time interview/meeting aid. Generate natural response suggestions."
                    },
                    {"role": "user", "content": prompt}
                ],
                text_format=SuggestionResponse
            )

            self._check_refusal(response)
            result = response.output_parsed
            result.context_used = has_context
            return result

        except RateLimitError as e:
            raise LLMRateLimitError(retry_after=getattr(e, 'retry_after', 60))
        except LLMError:
            raise
        except Exception as e:
            logger.error(f"Error generating suggestions: {e}", exc_info=True)
            # Return fallback suggestions
            return SuggestionResponse(
                question=question,
                suggestions=["I'd need a moment to think about that."],
                context_used=has_context
            )

    async def generate_recap_structured(
        self,
        transcript_text: str,
        duration_seconds: int = 30
    ) -> RecapOutput:
        """
        Generate 30-second recap with structured output.

        Args:
            transcript_text: Recent transcript text
            duration_seconds: Duration to recap

        Returns:
            RecapOutput structured object
        """
        try:
            response = await self.client.responses.parse(
                model=self.model,
                input=[
                    {
                        "role": "system",
                        "content": f"You are a meeting assistant. Generate a brief recap of the last {duration_seconds} seconds of conversation."
                    },
                    {"role": "user", "content": f"Transcript:\n{transcript_text}"}
                ],
                text_format=RecapOutput
            )

            self._check_refusal(response)
            return response.output_parsed

        except RateLimitError as e:
            raise LLMRateLimitError(retry_after=getattr(e, 'retry_after', 60))
        except LLMError:
            raise
        except Exception as e:
            logger.error(f"Error generating recap: {e}", exc_info=True)
            raise LLMError(
                message=str(e),
                code=ErrorCode.MODEL_ERROR,
                recoverable=True
            )

    # =========================================================================
    # Context-Aware Methods (using ContextBuilder)
    # =========================================================================

    async def generate_summary_with_context(
        self,
        context: dict,
        reasoning_effort: str = "low"
    ) -> EnhancedMeetingSummary:
        """
        Generate summary using unified context with document awareness.

        Args:
            context: Context dict from ContextBuilder.build()
            reasoning_effort: Reasoning effort level (low/medium/high)

        Returns:
            EnhancedMeetingSummary with document references
        """
        # Build prompt from context
        prompt_parts = []
        meeting = context.get("meeting", {})

        if meeting:
            prompt_parts.append(f"Meeting: {meeting.get('title', 'Untitled')}")
            if meeting.get('duration_minutes'):
                prompt_parts.append(f"Duration: {meeting['duration_minutes']} minutes")
            if meeting.get('platform'):
                prompt_parts.append(f"Platform: {meeting['platform']}")
            prompt_parts.append("")

        # Include previous summaries for continuity
        if context.get("summaries"):
            prompt_parts.append("Previous summaries:")
            for s in context["summaries"][-2:]:  # Last 2 summaries
                prompt_parts.append(f"- {s[:200]}...")
            prompt_parts.append("")

        # Include document context with attribution
        document_refs = []
        if context.get("documents"):
            prompt_parts.append("Relevant document context:")
            for doc in context["documents"]:
                prompt_parts.append(f"[{doc.document_filename}]: {doc.text[:300]}...")
                document_refs.append(doc.document_filename)
            prompt_parts.append("")

        # Include transcripts
        if context.get("transcripts"):
            prompt_parts.append("Conversation to summarize:")
            for t in context["transcripts"]:
                speaker = t.get("speaker", "unknown")
                text = t.get("text", "")
                prompt_parts.append(f"[{speaker}]: {text}")

        user_content = "\n".join(prompt_parts)

        if not user_content.strip():
            return EnhancedMeetingSummary(
                summary="No content to summarize.",
                key_points=[],
                document_references=[]
            )

        try:
            response = await self.client.responses.parse(
                model=self.model,
                input=[
                    {"role": "system", "content": SYSTEM_PROMPTS["summary"]},
                    {"role": "user", "content": user_content}
                ],
                text_format=EnhancedMeetingSummary,
                reasoning={"effort": reasoning_effort}
            )

            self._check_refusal(response)
            result = response.output_parsed

            # Ensure document references are populated
            if not result.document_references and document_refs:
                result.document_references = list(set(document_refs))

            logger.info(f"generate_summary_with_context: success, "
                       f"key_points={len(result.key_points)}, "
                       f"doc_refs={len(result.document_references)}")

            return result

        except RateLimitError as e:
            raise LLMRateLimitError(retry_after=getattr(e, 'retry_after', 60))
        except LLMError:
            raise
        except Exception as e:
            logger.error(f"Error generating context-aware summary: {e}", exc_info=True)
            raise LLMError(
                message=str(e),
                code=ErrorCode.MODEL_ERROR,
                recoverable=True
            )

    async def generate_suggestion_with_context(
        self,
        question: str,
        context: dict
    ) -> EnhancedSuggestionResponse:
        """
        Generate response suggestions using unified context.

        Args:
            question: The detected question to respond to
            context: Context dict from ContextBuilder.build()

        Returns:
            EnhancedSuggestionResponse with document sources
        """
        # Build prompt
        prompt_parts = []

        # Document context
        document_sources = []
        if context.get("documents"):
            prompt_parts.append("User's Background / Context (from documents):")
            for doc in context["documents"]:
                prompt_parts.append(f"[{doc.document_filename}]: {doc.text}")
                document_sources.append(doc.document_filename)
        else:
            prompt_parts.append("User's Background: No documents uploaded.")
        prompt_parts.append("")

        # Transcript context
        if context.get("transcripts"):
            prompt_parts.append("Recent Conversation:")
            for t in context["transcripts"]:
                speaker = t.get("speaker", "unknown")
                text = t.get("text", "")
                prompt_parts.append(f"[{speaker}]: {text}")
        prompt_parts.append("")

        prompt_parts.append(f"Question Detected:\n{question}")

        user_content = "\n".join(prompt_parts)

        try:
            response = await self.client.responses.parse(
                model=self.model,
                input=[
                    {"role": "system", "content": SYSTEM_PROMPTS["suggestion"]},
                    {"role": "user", "content": user_content}
                ],
                text_format=EnhancedSuggestionResponse
            )

            self._check_refusal(response)
            result = response.output_parsed

            # Populate document sources
            result.context_used = bool(document_sources)
            if not result.document_sources and document_sources:
                result.document_sources = list(set(document_sources))

            return result

        except RateLimitError as e:
            raise LLMRateLimitError(retry_after=getattr(e, 'retry_after', 60))
        except LLMError:
            raise
        except Exception as e:
            logger.error(f"Error generating context-aware suggestions: {e}", exc_info=True)
            return EnhancedSuggestionResponse(
                question=question,
                suggestions=["I'd need a moment to think about that."],
                context_used=bool(document_sources),
                document_sources=document_sources
            )

    async def answer_query_with_context(
        self,
        question: str,
        context: dict,
        reasoning_effort: str = "medium"
    ) -> AsyncGenerator[str, None]:
        """
        Stream answer to user query using unified context with document attribution.

        Args:
            question: User's question
            context: Context dict from ContextBuilder.build()
            reasoning_effort: Reasoning effort level

        Yields:
            Answer text chunks as they are generated
        """
        # Format context for prompt
        prompt_parts = []

        # Meeting info
        meeting = context.get("meeting", {})
        if meeting.get("title"):
            prompt_parts.append(f"Meeting: {meeting['title']}")

        # Summaries
        if context.get("summaries"):
            prompt_parts.append("\n## Summaries")
            for s in context["summaries"]:
                prompt_parts.append(s)

        # Documents with attribution
        if context.get("documents"):
            prompt_parts.append("\n## Relevant Documents")
            for doc in context["documents"]:
                prompt_parts.append(f"[From: {doc.document_filename} (relevance: {doc.relevance_score:.0%})]")
                prompt_parts.append(doc.text)

        # Transcripts
        if context.get("transcripts"):
            prompt_parts.append("\n## Recent Conversation")
            for t in context["transcripts"]:
                speaker = t.get("speaker", "unknown")
                text = t.get("text", "")
                prompt_parts.append(f"[{speaker}]: {text}")

        formatted_context = "\n".join(prompt_parts)

        logger.info(f"answer_query_with_context: model={self.model}, question_len={len(question)}, "
                   f"context_len={len(formatted_context)}, docs={len(context.get('documents', []))}")

        try:
            response = await self.client.responses.create(
                model=self.model,
                instructions=SYSTEM_PROMPTS["query"],
                input=f"Context:\n{formatted_context}\n\nQuestion: {question}",
                max_output_tokens=1000,
                reasoning={"effort": reasoning_effort},
                stream=True
            )

            chunk_count = 0
            total_chars = 0

            async for event in response:
                # Extract text from streaming events
                delta = getattr(event, 'delta', None)
                if delta:
                    if isinstance(delta, str):
                        chunk_count += 1
                        total_chars += len(delta)
                        yield delta
                    elif hasattr(delta, 'text') and delta.text:
                        chunk_count += 1
                        total_chars += len(delta.text)
                        yield delta.text

            logger.info(f"answer_query_with_context: completed, chunks={chunk_count}, chars={total_chars}")

            if chunk_count == 0:
                yield "No response generated. Please try again."

        except RateLimitError as e:
            yield f"Rate limit exceeded. Please wait {getattr(e, 'retry_after', 60)} seconds."
        except APIError as e:
            logger.error(f"answer_query_with_context: API error - {e}")
            yield f"API Error: {str(e)}"
        except Exception as e:
            logger.error(f"answer_query_with_context: unexpected error - {e}", exc_info=True)
            yield f"Error generating response: {str(e)}"
