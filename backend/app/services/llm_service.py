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
    RecapOutput, ErrorCode
)

logger = logging.getLogger(__name__)


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
        """
        try:
            if not response.output:
                logger.warning("_extract_text: response.output is empty/None")
                return ""

            # Log the response structure for debugging
            output_types = [getattr(item, 'type', 'unknown') for item in response.output]
            logger.debug(f"_extract_text: output item types: {output_types}")

            # Find the message item (may not be first due to reasoning)
            for item in response.output:
                if hasattr(item, 'type') and item.type == "message":
                    if hasattr(item, 'content') and item.content:
                        for content_part in item.content:
                            if hasattr(content_part, 'type') and content_part.type == "output_text":
                                logger.debug(f"_extract_text: found output_text, length={len(content_part.text)}")
                                return content_part.text
                            elif hasattr(content_part, 'text'):
                                logger.debug(f"_extract_text: found text attr, length={len(content_part.text)}")
                                return content_part.text

            logger.warning("_extract_text: no message item with text content found in response")
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

            async for event in response:
                event_type = getattr(event, 'type', None)
                event_types_seen.add(event_type)

                # Handle streaming events from Responses API
                # Check for delta directly on the event (primary method)
                delta = getattr(event, 'delta', None)
                if delta:
                    logger.debug(f"answer_query_stream: event_type={event_type}, delta={repr(delta)[:100]}")
                    chunk_count += 1
                    total_chars += len(delta)
                    yield delta
                    continue

                # Check for specific Responses API event types
                if event_type == "response.output_text.delta":
                    if hasattr(event, 'delta') and event.delta:
                        chunk_count += 1
                        total_chars += len(event.delta)
                        yield event.delta
                        continue
                elif event_type == "response.text.delta":
                    if hasattr(event, 'delta') and event.delta:
                        chunk_count += 1
                        total_chars += len(event.delta)
                        yield event.delta
                        continue
                elif event_type == "response.content_part.delta":
                    # Alternative event type for content parts
                    if hasattr(event, 'delta') and event.delta:
                        chunk_count += 1
                        total_chars += len(event.delta)
                        yield event.delta
                        continue

                # Check for text in other locations as fallback
                if hasattr(event, 'text') and event.text:
                    logger.debug(f"answer_query_stream: found text attr on event_type={event_type}")
                    chunk_count += 1
                    total_chars += len(event.text)
                    yield event.text

            logger.info(f"answer_query_stream: completed, chunks={chunk_count}, total_chars={total_chars}, "
                       f"event_types={event_types_seen}")

            if chunk_count == 0:
                logger.warning("answer_query_stream: no text chunks received from streaming response")
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
