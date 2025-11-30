# Error Handling Strategies

## Table of Contents
1. [Refusal Detection](#refusal-detection)
2. [Retry Logic](#retry-logic)
3. [Token Limit Management](#token-limit-management)
4. [Graceful Degradation](#graceful-degradation)
5. [Error Response Schemas](#error-response-schemas)

---

## Refusal Detection

### Handling Model Refusals

```python
from pydantic import BaseModel
from typing import Optional
from openai import OpenAI

class ExtractionResult(BaseModel):
    success: bool
    data: Optional[dict] = None
    refusal_reason: Optional[str] = None

async def extract_with_refusal_handling(
    client: OpenAI,
    transcript: str
) -> ExtractionResult:
    """Handle cases where model refuses to process content"""
    response = client.responses.parse(
        model="gpt-5-nano-2025-08-07",
        input=[
            {"role": "system", "content": "Extract meeting action items."},
            {"role": "user", "content": transcript}
        ],
        text_format=MeetingSummary
    )

    # Check for refusal
    if response.refusal:
        return ExtractionResult(
            success=False,
            refusal_reason=response.refusal
        )

    return ExtractionResult(
        success=True,
        data=response.output_parsed.dict()
    )
```

### Refusal Recovery Strategies

```python
from enum import Enum

class RefusalType(str, Enum):
    CONTENT_POLICY = "content_policy"
    UNCLEAR_REQUEST = "unclear_request"
    INSUFFICIENT_CONTEXT = "insufficient_context"
    UNKNOWN = "unknown"

def classify_refusal(refusal_message: str) -> RefusalType:
    """Classify refusal to determine recovery strategy"""
    message_lower = refusal_message.lower()

    if any(word in message_lower for word in ["policy", "inappropriate", "harmful"]):
        return RefusalType.CONTENT_POLICY
    elif any(word in message_lower for word in ["unclear", "ambiguous", "specify"]):
        return RefusalType.UNCLEAR_REQUEST
    elif any(word in message_lower for word in ["context", "information", "details"]):
        return RefusalType.INSUFFICIENT_CONTEXT

    return RefusalType.UNKNOWN

async def recover_from_refusal(
    client: OpenAI,
    transcript: str,
    refusal_type: RefusalType
) -> Optional[dict]:
    """Attempt recovery based on refusal type"""

    if refusal_type == RefusalType.CONTENT_POLICY:
        # Cannot recover - content violates policy
        return None

    elif refusal_type == RefusalType.UNCLEAR_REQUEST:
        # Retry with more specific prompt
        return await client.responses.parse(
            model="gpt-5-nano-2025-08-07",
            input=[
                {
                    "role": "system",
                    "content": """Extract ONLY these items from the meeting transcript:
1. Action items (tasks assigned to people)
2. Decisions made
3. Key discussion topics

Format each as a bullet point."""
                },
                {"role": "user", "content": transcript}
            ],
            text_format=MeetingSummary
        ).output_parsed

    elif refusal_type == RefusalType.INSUFFICIENT_CONTEXT:
        # Retry with context prompt
        return await client.responses.parse(
            model="gpt-5-nano-2025-08-07",
            input=[
                {
                    "role": "system",
                    "content": "Extract what you can from this partial transcript. Mark uncertain items."
                },
                {"role": "user", "content": f"[Partial transcript]\n\n{transcript}"}
            ],
            text_format=MeetingSummary
        ).output_parsed

    return None
```

---

## Retry Logic

### Exponential Backoff with Jitter

```python
import asyncio
import random
from typing import TypeVar, Callable
from openai import RateLimitError, APIError

T = TypeVar('T')

async def retry_with_backoff(
    func: Callable[[], T],
    max_retries: int = 3,
    base_delay: float = 1.0,
    max_delay: float = 60.0
) -> T:
    """Retry with exponential backoff and jitter"""
    last_exception = None

    for attempt in range(max_retries):
        try:
            return await func()
        except RateLimitError as e:
            last_exception = e
            # Calculate delay with jitter
            delay = min(base_delay * (2 ** attempt), max_delay)
            jitter = random.uniform(0, delay * 0.1)
            await asyncio.sleep(delay + jitter)
        except APIError as e:
            if e.status_code >= 500:  # Server error, retry
                last_exception = e
                delay = min(base_delay * (2 ** attempt), max_delay)
                await asyncio.sleep(delay)
            else:  # Client error, don't retry
                raise

    raise last_exception
```

### Retry with Fallback Model

```python
from dataclasses import dataclass
from typing import List

@dataclass
class ModelConfig:
    name: str
    priority: int
    max_tokens: int

class ResilientLLMClient:
    """Client with automatic model fallback"""

    MODELS: List[ModelConfig] = [
        ModelConfig("gpt-5-nano-2025-08-07", 1, 128000),
        ModelConfig("gpt-4o-mini", 2, 128000),
        ModelConfig("gpt-3.5-turbo", 3, 16385),
    ]

    def __init__(self, client: OpenAI):
        self.client = client

    async def parse_with_fallback(
        self,
        messages: List[dict],
        schema: type,
        max_retries: int = 2
    ) -> dict:
        """Try primary model, fall back to alternatives on failure"""
        last_error = None

        for model_config in sorted(self.MODELS, key=lambda m: m.priority):
            for attempt in range(max_retries):
                try:
                    response = self.client.responses.parse(
                        model=model_config.name,
                        input=messages,
                        text_format=schema
                    )
                    return {
                        "data": response.output_parsed.dict(),
                        "model_used": model_config.name,
                        "fallback": model_config.priority > 1
                    }
                except RateLimitError:
                    await asyncio.sleep(2 ** attempt)
                except Exception as e:
                    last_error = e
                    break  # Try next model

        raise last_error or Exception("All models failed")
```

### Circuit Breaker Pattern

```python
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum

class CircuitState(str, Enum):
    CLOSED = "closed"      # Normal operation
    OPEN = "open"          # Failing, reject requests
    HALF_OPEN = "half_open" # Testing if recovered

@dataclass
class CircuitBreaker:
    failure_threshold: int = 5
    recovery_timeout: timedelta = timedelta(seconds=30)

    state: CircuitState = CircuitState.CLOSED
    failures: int = 0
    last_failure_time: datetime = None

    def record_success(self):
        self.failures = 0
        self.state = CircuitState.CLOSED

    def record_failure(self):
        self.failures += 1
        self.last_failure_time = datetime.now()

        if self.failures >= self.failure_threshold:
            self.state = CircuitState.OPEN

    def can_execute(self) -> bool:
        if self.state == CircuitState.CLOSED:
            return True

        if self.state == CircuitState.OPEN:
            if datetime.now() - self.last_failure_time > self.recovery_timeout:
                self.state = CircuitState.HALF_OPEN
                return True
            return False

        return True  # HALF_OPEN allows one request

class ProtectedLLMClient:
    def __init__(self, client: OpenAI):
        self.client = client
        self.circuit = CircuitBreaker()

    async def call(self, messages: List[dict], schema: type) -> dict:
        if not self.circuit.can_execute():
            raise Exception("Circuit breaker open - service unavailable")

        try:
            result = self.client.responses.parse(
                model="gpt-5-nano-2025-08-07",
                input=messages,
                text_format=schema
            )
            self.circuit.record_success()
            return result.output_parsed.dict()
        except Exception as e:
            self.circuit.record_failure()
            raise
```

---

## Token Limit Management

### Token Counting and Context Truncation

```python
import tiktoken

class TokenManager:
    """Manage token budgets for LLM calls"""

    def __init__(self, model: str = "gpt-5-nano-2025-08-07"):
        self.encoding = tiktoken.encoding_for_model(model)
        self.max_context = 128000  # Model-specific
        self.max_output = 16384

    def count_tokens(self, text: str) -> int:
        return len(self.encoding.encode(text))

    def truncate_to_budget(
        self,
        text: str,
        max_tokens: int,
        strategy: str = "end"
    ) -> str:
        """Truncate text to fit token budget"""
        tokens = self.encoding.encode(text)

        if len(tokens) <= max_tokens:
            return text

        if strategy == "end":
            # Keep beginning, truncate end
            truncated = tokens[:max_tokens]
        elif strategy == "start":
            # Keep end, truncate beginning
            truncated = tokens[-max_tokens:]
        else:  # middle
            # Keep beginning and end
            half = max_tokens // 2
            truncated = tokens[:half] + tokens[-half:]

        return self.encoding.decode(truncated)

    def calculate_budget(
        self,
        system_prompt: str,
        user_context: str,
        reserved_output: int = 4096
    ) -> dict:
        """Calculate available tokens for each component"""
        system_tokens = self.count_tokens(system_prompt)
        available = self.max_context - system_tokens - reserved_output

        context_tokens = self.count_tokens(user_context)

        return {
            "system_tokens": system_tokens,
            "context_tokens": min(context_tokens, available),
            "available_for_context": available,
            "reserved_output": reserved_output,
            "needs_truncation": context_tokens > available
        }
```

### Smart Context Compression

```python
async def compress_context(
    client: OpenAI,
    long_context: str,
    target_tokens: int
) -> str:
    """Use LLM to compress context while preserving key information"""
    current_tokens = TokenManager().count_tokens(long_context)

    if current_tokens <= target_tokens:
        return long_context

    compression_ratio = target_tokens / current_tokens

    response = client.responses.parse(
        model="gpt-5-nano-2025-08-07",
        input=[
            {
                "role": "system",
                "content": f"""Compress this text to approximately {int(compression_ratio * 100)}% of its length.
Preserve:
- All action items and owners
- Key decisions
- Important dates/deadlines
- Speaker attributions for important statements

Remove:
- Filler words and pleasantries
- Redundant information
- Tangential discussions"""
            },
            {"role": "user", "content": long_context}
        ],
        text_format=CompressedContext
    )

    return response.output_parsed.compressed_text
```

### Rolling Context Window

```python
from collections import deque
from dataclasses import dataclass

@dataclass
class ContextSegment:
    text: str
    tokens: int
    timestamp: float
    importance: float = 1.0

class RollingContextWindow:
    """Maintain context within token budget using sliding window"""

    def __init__(self, max_tokens: int = 100000):
        self.max_tokens = max_tokens
        self.segments: deque[ContextSegment] = deque()
        self.current_tokens = 0
        self.token_manager = TokenManager()

    def add_segment(self, text: str, importance: float = 1.0):
        tokens = self.token_manager.count_tokens(text)
        segment = ContextSegment(
            text=text,
            tokens=tokens,
            timestamp=time.time(),
            importance=importance
        )

        # Remove old segments if needed
        while self.current_tokens + tokens > self.max_tokens and self.segments:
            # Remove lowest importance first, then oldest
            to_remove = min(self.segments, key=lambda s: (s.importance, -s.timestamp))
            self.segments.remove(to_remove)
            self.current_tokens -= to_remove.tokens

        self.segments.append(segment)
        self.current_tokens += tokens

    def get_context(self) -> str:
        """Get current context sorted by timestamp"""
        sorted_segments = sorted(self.segments, key=lambda s: s.timestamp)
        return "\n\n".join(s.text for s in sorted_segments)
```

---

## Graceful Degradation

### Tiered Response Quality

```python
from enum import Enum

class ResponseQuality(str, Enum):
    FULL = "full"           # Complete analysis
    REDUCED = "reduced"     # Key points only
    MINIMAL = "minimal"     # Basic extraction

async def extract_with_degradation(
    client: OpenAI,
    transcript: str,
    timeout_seconds: int = 30
) -> dict:
    """Attempt full extraction, degrade on timeout/error"""

    # Try full extraction
    try:
        return await asyncio.wait_for(
            full_extraction(client, transcript),
            timeout=timeout_seconds
        )
    except asyncio.TimeoutError:
        pass

    # Fall back to reduced extraction
    try:
        return await asyncio.wait_for(
            reduced_extraction(client, transcript),
            timeout=timeout_seconds // 2
        )
    except asyncio.TimeoutError:
        pass

    # Minimal extraction (rule-based, no LLM)
    return minimal_extraction(transcript)

def minimal_extraction(transcript: str) -> dict:
    """Rule-based extraction when LLM unavailable"""
    # Simple keyword matching
    action_keywords = ["action item", "todo", "will do", "assigned to", "deadline"]
    decision_keywords = ["decided", "agreed", "conclusion", "resolution"]

    lines = transcript.split('\n')
    actions = [l for l in lines if any(k in l.lower() for k in action_keywords)]
    decisions = [l for l in lines if any(k in l.lower() for k in decision_keywords)]

    return {
        "quality": ResponseQuality.MINIMAL,
        "action_items": actions[:5],
        "decisions": decisions[:3],
        "note": "Extracted using rule-based fallback"
    }
```

### Partial Result Handling

```python
from pydantic import BaseModel, validator
from typing import List, Optional

class PartialMeetingSummary(BaseModel):
    """Schema that accepts partial results"""
    title: Optional[str] = None
    summary: Optional[str] = None
    action_items: List[str] = []
    decisions: List[str] = []
    completeness: float = 0.0

    @validator('completeness', always=True)
    def calculate_completeness(cls, v, values):
        filled = sum(1 for v in values.values() if v)
        total = len(values)
        return filled / total if total > 0 else 0.0

async def extract_partial(
    client: OpenAI,
    transcript: str
) -> PartialMeetingSummary:
    """Extract what's possible, mark missing fields"""
    try:
        response = client.responses.parse(
            model="gpt-5-nano-2025-08-07",
            input=[
                {"role": "system", "content": "Extract available meeting information. Leave unknown fields empty."},
                {"role": "user", "content": transcript}
            ],
            text_format=PartialMeetingSummary
        )
        return response.output_parsed
    except Exception:
        return PartialMeetingSummary()
```

---

## Error Response Schemas

### Structured Error Responses

```python
from pydantic import BaseModel
from typing import Optional, List
from enum import Enum

class ErrorCode(str, Enum):
    RATE_LIMIT = "rate_limit"
    TOKEN_LIMIT = "token_limit"
    CONTENT_POLICY = "content_policy"
    MODEL_ERROR = "model_error"
    TIMEOUT = "timeout"
    PARSE_ERROR = "parse_error"
    UNKNOWN = "unknown"

class ErrorDetail(BaseModel):
    code: ErrorCode
    message: str
    recoverable: bool
    retry_after_seconds: Optional[int] = None
    suggestions: List[str] = []

class LLMResponse(BaseModel):
    """Wrapper for all LLM responses"""
    success: bool
    data: Optional[dict] = None
    error: Optional[ErrorDetail] = None
    metadata: dict = {}

def create_error_response(
    exception: Exception,
    context: str = ""
) -> LLMResponse:
    """Convert exceptions to structured error responses"""

    if isinstance(exception, RateLimitError):
        return LLMResponse(
            success=False,
            error=ErrorDetail(
                code=ErrorCode.RATE_LIMIT,
                message="Rate limit exceeded",
                recoverable=True,
                retry_after_seconds=60,
                suggestions=["Wait and retry", "Reduce request frequency"]
            )
        )

    if isinstance(exception, asyncio.TimeoutError):
        return LLMResponse(
            success=False,
            error=ErrorDetail(
                code=ErrorCode.TIMEOUT,
                message="Request timed out",
                recoverable=True,
                suggestions=["Try shorter input", "Use faster model"]
            )
        )

    # Generic error
    return LLMResponse(
        success=False,
        error=ErrorDetail(
            code=ErrorCode.UNKNOWN,
            message=str(exception),
            recoverable=False,
            suggestions=["Check logs for details"]
        )
    )
```

### Error Logging and Monitoring

```python
import logging
from datetime import datetime
from typing import Dict, Any

logger = logging.getLogger(__name__)

class LLMErrorTracker:
    """Track and analyze LLM errors for monitoring"""

    def __init__(self):
        self.errors: List[Dict[str, Any]] = []

    def log_error(
        self,
        error_code: ErrorCode,
        message: str,
        context: dict = None
    ):
        error_record = {
            "timestamp": datetime.now().isoformat(),
            "code": error_code,
            "message": message,
            "context": context or {}
        }
        self.errors.append(error_record)

        # Log for monitoring
        logger.error(
            f"LLM Error: {error_code.value}",
            extra={
                "error_code": error_code.value,
                "message": message,
                **error_record["context"]
            }
        )

    def get_error_summary(self, hours: int = 24) -> dict:
        """Get error statistics for monitoring dashboard"""
        cutoff = datetime.now() - timedelta(hours=hours)
        recent = [e for e in self.errors if datetime.fromisoformat(e["timestamp"]) > cutoff]

        by_code = {}
        for error in recent:
            code = error["code"]
            by_code[code] = by_code.get(code, 0) + 1

        return {
            "total_errors": len(recent),
            "by_code": by_code,
            "error_rate": len(recent) / hours if hours > 0 else 0
        }
```
