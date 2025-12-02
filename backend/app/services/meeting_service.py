import asyncio
import logging
from typing import Optional, List
from datetime import datetime, timedelta, timezone

from app.services.audio_capture import AudioCaptureService, AudioChunk
from app.services.transcription import get_transcription_service, TranscriptionService
from app.services.websocket_manager import manager
from app.services.llm_service import LLMService
from app.services.context_service import ContextService
from app.services.context_builder import ContextBuilder, CONTEXT_PRESETS
from app.db.session import AsyncSessionLocal
from uuid import UUID
from app.models.transcript import Transcript
from app.models.meeting import Meeting, MeetingStatus
from app.models.summary import Summary
from app.models.suggestion import Suggestion
from app.config import settings
from sqlalchemy import select

logger = logging.getLogger(__name__)

# Conditional import for Realtime API
if settings.USE_REALTIME_API:
    try:
        from app.services.realtime_transcription import (
            get_realtime_transcription_service,
            RealtimeTranscriptionService,
            resample_to_24khz,
            TranscriptDelta
        )
        REALTIME_AVAILABLE = True
        logger.info("Realtime API imports successful")
    except ImportError as e:
        logger.warning(f"Realtime API not available: {e}. Falling back to Whisper.")
        REALTIME_AVAILABLE = False
else:
    REALTIME_AVAILABLE = False

class MeetingService:
    def __init__(self):
        self.audio_capture = AudioCaptureService()
        self.transcription_service = get_transcription_service()
        self.llm_service = LLMService()
        self.current_meeting_id: Optional[str] = None
        self.capture_task: Optional[asyncio.Task] = None
        self.summary_task: Optional[asyncio.Task] = None
        self.realtime_task: Optional[asyncio.Task] = None  # For Realtime API receiver
        self.is_running = False
        self.is_paused = False  # Pause state for privacy feature

        # Realtime API service (lazy initialized)
        self.realtime_service: Optional['RealtimeTranscriptionService'] = None
        self.use_realtime = REALTIME_AVAILABLE and settings.USE_REALTIME_API

        # Meeting timing - for calculating transcript offsets
        self.meeting_start_loop_time: Optional[float] = None  # Event loop time when meeting started

        # Buffers for AI processing
        self.transcript_buffer: List[str] = []
        self.last_summary_time = datetime.now(timezone.utc)

        # Transcript batching: accumulate text until sentence boundary or timeout
        # Simplified: single accumulator for unified transcript (no speaker separation)
        self.transcript_accumulator: str = ""
        self.last_broadcast_time: Optional[datetime] = None
        self.batch_timeout_seconds = 3.0  # Max time to wait before broadcasting partial text

        logger.info(f"MeetingService initialized. Realtime API: {'enabled' if self.use_realtime else 'disabled (using Whisper)'}")

    async def start_meeting(self, meeting_id: str):
        """
        Start the meeting processing pipeline.
        If another meeting is running, stop it first.
        """
        if self.is_running:
            if self.current_meeting_id == meeting_id:
                logger.info(f"Meeting {meeting_id} already running, skipping start")
                return
            # Stop the existing meeting before starting a new one
            logger.warning(f"Stopping existing meeting {self.current_meeting_id} to start {meeting_id}")
            await self.stop_meeting(self.current_meeting_id)

        self.current_meeting_id = meeting_id
        self.is_running = True
        self.transcript_buffer = []
        self.last_summary_time = datetime.now(timezone.utc)

        # Record meeting start time for timestamp offset calculation
        self.meeting_start_loop_time = asyncio.get_event_loop().time()

        # Reset transcript batching state (simplified: single accumulator)
        self.transcript_accumulator = ""
        self.last_broadcast_time = None
        
        # Update meeting status in DB
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Meeting).where(Meeting.id == meeting_id))
            meeting = result.scalars().first()
            if meeting:
                meeting.status = MeetingStatus.IN_PROGRESS
                await db.commit()

        # Start the capture loop in the background
        self.capture_task = asyncio.create_task(self._processing_loop(meeting_id))
        # Start summarization loop
        self.summary_task = asyncio.create_task(self._summarization_loop(meeting_id))
        
        logger.info(f"Started meeting processing for {meeting_id}")

    async def stop_meeting(self, meeting_id: str):
        """
        Stop the meeting processing pipeline.
        """
        if not self.is_running:
            return

        self.is_running = False
        
        # Cancel tasks
        for task in [self.capture_task, self.summary_task]:
            if task:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
        
        self.capture_task = None
        self.summary_task = None

        await self.audio_capture.stop_capture()
        
        # Update meeting status in DB
        async with AsyncSessionLocal() as db:
            result = await db.execute(select(Meeting).where(Meeting.id == meeting_id))
            meeting = result.scalars().first()
            if meeting:
                meeting.status = MeetingStatus.COMPLETED
                meeting.end_time = datetime.now(timezone.utc)
                await db.commit()

        self.current_meeting_id = None
        logger.info(f"Stopped meeting processing for {meeting_id}")

    async def pause_meeting(self, meeting_id: str):
        """
        Pause meeting audio capture (privacy feature).
        Audio is not captured/transcribed while paused.
        """
        if not self.is_running or meeting_id != self.current_meeting_id:
            logger.warning(f"Cannot pause: meeting {meeting_id} not active")
            return False

        self.is_paused = True
        logger.info(f"Paused meeting {meeting_id}")

        # Broadcast pause status
        await manager.broadcast_to_meeting({
            "type": "meeting_status",
            "data": {"status": "paused", "meeting_id": meeting_id}
        }, meeting_id)

        return True

    async def resume_meeting(self, meeting_id: str):
        """
        Resume meeting audio capture after pause.
        """
        if not self.is_running or meeting_id != self.current_meeting_id:
            logger.warning(f"Cannot resume: meeting {meeting_id} not active")
            return False

        self.is_paused = False
        logger.info(f"Resumed meeting {meeting_id}")

        # Broadcast resume status
        await manager.broadcast_to_meeting({
            "type": "meeting_status",
            "data": {"status": "recording", "meeting_id": meeting_id}
        }, meeting_id)

        return True

    def get_status(self) -> dict:
        """Get current meeting status."""
        return {
            "is_running": self.is_running,
            "is_paused": self.is_paused,
            "meeting_id": self.current_meeting_id
        }

    async def _processing_loop(self, meeting_id: str):
        """
        Main loop: Capture -> Transcribe -> Save -> Broadcast -> AI Triggers

        Uses Realtime API if enabled, otherwise falls back to batch Whisper.
        """
        logger.info(f"Starting audio processing loop (Realtime API: {self.use_realtime})")

        if self.use_realtime:
            await self._processing_loop_realtime(meeting_id)
        else:
            await self._processing_loop_whisper(meeting_id)

    async def _processing_loop_whisper(self, meeting_id: str):
        """Process audio using batch Whisper API (fallback)."""
        logger.info("Using batch Whisper API for transcription")
        try:
            async for chunk in self.audio_capture.capture_audio():
                if not self.is_running:
                    break
                # Skip processing when paused (privacy feature)
                if self.is_paused:
                    continue
                asyncio.create_task(self._handle_chunk(chunk, meeting_id))

        except Exception as e:
            logger.error(f"Error in Whisper processing loop: {e}", exc_info=True)
        finally:
            logger.info("Whisper processing loop ended")

    async def _processing_loop_realtime(self, meeting_id: str):
        """Process audio using OpenAI Realtime API for low-latency transcription."""
        logger.info(f"=" * 50)
        logger.info(f"=== STARTING REALTIME API PROCESSING ===")
        logger.info(f"Meeting ID: {meeting_id}")
        logger.info(f"=" * 50)

        try:
            # Initialize Realtime API service
            logger.info("Initializing Realtime API service...")
            self.realtime_service = get_realtime_transcription_service()

            # Connect to Realtime API
            logger.info("Connecting to Realtime API...")
            connected = await self.realtime_service.connect()
            if not connected:
                logger.error("=" * 50)
                logger.error("FAILED TO CONNECT TO REALTIME API")
                logger.error("Falling back to Whisper batch API")
                logger.error("=" * 50)
                self.use_realtime = False
                await self._processing_loop_whisper(meeting_id)
                return

            logger.info(f"Connected! Session ID: {self.realtime_service.session_id}")

            # Start task to receive transcripts
            logger.info("Starting transcript receiver task...")
            self.realtime_task = asyncio.create_task(
                self._handle_realtime_transcripts(meeting_id)
            )

            # Send audio chunks to Realtime API
            chunk_count = 0
            total_audio_seconds = 0
            last_log_time = asyncio.get_event_loop().time()

            logger.info("Starting audio capture loop...")
            async for chunk in self.audio_capture.capture_audio():
                if not self.is_running:
                    logger.info("Meeting stopped, exiting audio loop")
                    break

                # Skip processing when paused (privacy feature)
                if self.is_paused:
                    continue

                chunk_count += 1
                total_audio_seconds += chunk.duration if hasattr(chunk, 'duration') else 1.0

                # Log progress every 10 seconds of audio or every 10 chunks
                current_time = asyncio.get_event_loop().time()
                if chunk_count % 10 == 1 or (current_time - last_log_time) >= 10:
                    logger.info(f"Audio progress: chunk #{chunk_count}, ~{total_audio_seconds:.1f}s total, "
                               f"audio_level={getattr(chunk, 'audio_level', 0):.3f}")
                    last_log_time = current_time

                # Resample to 24kHz if needed
                if chunk.sample_rate != settings.REALTIME_SAMPLE_RATE:
                    audio_24k = resample_to_24khz(chunk.data, chunk.sample_rate)
                else:
                    audio_24k = chunk.data

                # Send to Realtime API
                await self.realtime_service.send_audio_numpy(audio_24k)

            logger.info(f"Audio capture complete: {chunk_count} chunks, ~{total_audio_seconds:.1f}s total")

        except Exception as e:
            logger.error(f"=" * 50)
            logger.error(f"ERROR IN REALTIME PROCESSING: {type(e).__name__}: {e}")
            logger.error(f"=" * 50, exc_info=True)
            # Attempt fallback to Whisper
            if self.is_running:
                logger.info("Attempting fallback to Whisper API...")
                self.use_realtime = False
                await self._processing_loop_whisper(meeting_id)

        finally:
            # Cleanup Realtime API
            logger.info("Cleaning up Realtime API resources...")
            if self.realtime_task:
                self.realtime_task.cancel()
                try:
                    await self.realtime_task
                except asyncio.CancelledError:
                    pass

            if self.realtime_service:
                await self.realtime_service.close()
                self.realtime_service = None

            logger.info("=== REALTIME PROCESSING ENDED ===")

    async def _handle_realtime_transcripts(self, meeting_id: str):
        """Handle streaming transcripts from Realtime API."""
        logger.info(f"=== TRANSCRIPT HANDLER STARTED ===")
        logger.info(f"Meeting ID: {meeting_id}")

        if not self.realtime_service:
            logger.error("No realtime_service instance - cannot receive transcripts!")
            return

        transcript_count = 0

        try:
            async for transcript in self.realtime_service.receive_transcripts():
                if not self.is_running:
                    logger.info("Meeting stopped, exiting transcript handler")
                    break

                if self.is_paused:
                    continue

                # Only process final transcripts (complete sentences)
                # Realtime API with VAD provides natural sentence boundaries
                if transcript.is_final and transcript.text.strip():
                    transcript_count += 1
                    logger.info(f"=== TRANSCRIPT #{transcript_count} ===")
                    logger.info(f"  Text: '{transcript.text.strip()[:100]}{'...' if len(transcript.text) > 100 else ''}'")
                    logger.info(f"  Timestamp: {transcript.timestamp:.2f}s")

                    await self._handle_realtime_transcript(
                        transcript.text.strip(),
                        transcript.timestamp,
                        meeting_id
                    )
                else:
                    # Log partial transcripts at debug level
                    logger.debug(f"Partial transcript: '{transcript.text[:50] if transcript.text else ''}...'")

        except asyncio.CancelledError:
            logger.info(f"Transcript handler cancelled. Total transcripts processed: {transcript_count}")
        except Exception as e:
            logger.error(f"Error in transcript handler: {type(e).__name__}: {e}", exc_info=True)

        logger.info(f"=== TRANSCRIPT HANDLER ENDED (processed {transcript_count} transcripts) ===")

    async def _handle_realtime_transcript(self, text: str, timestamp: float, meeting_id: str):
        """Save and broadcast a transcript from Realtime API."""
        try:
            # Unified transcript - no speaker separation needed
            # LLM orchestration focuses on content, not speaker attribution
            speaker = "meeting"

            # Calculate offset from meeting start (not raw event loop time)
            if self.meeting_start_loop_time is not None:
                offset_timestamp = timestamp - self.meeting_start_loop_time
            else:
                offset_timestamp = 0.0
                logger.warning("meeting_start_loop_time not set, using 0 for timestamp")

            async with AsyncSessionLocal() as db:
                transcript = Transcript(
                    meeting_id=meeting_id,
                    text=text,
                    timestamp=offset_timestamp,
                    speaker=speaker
                )
                db.add(transcript)
                await db.commit()
                await db.refresh(transcript)

                # Update buffer for summarization
                self.transcript_buffer.append(text)

                # Broadcast transcript
                await manager.broadcast_to_meeting({
                    "type": "transcript",
                    "data": {
                        "id": str(transcript.id),
                        "text": transcript.text,
                        "timestamp": transcript.timestamp,
                        "speaker": transcript.speaker,
                        "created_at": transcript.created_at.isoformat()
                    }
                }, meeting_id)

                # AI: Check for questions
                asyncio.create_task(self._process_ai_suggestions(meeting_id, text, db))

        except Exception as e:
            logger.error(f"Error handling Realtime transcript: {e}")

    async def _summarization_loop(self, meeting_id: str):
        """
        Periodic loop to generate summaries at configured interval (default 30s).
        """
        interval = settings.SUMMARY_INTERVAL
        logger.info(f"Starting summarization loop (interval: {interval}s)")
        try:
            while self.is_running:
                await asyncio.sleep(interval)  # Use configured interval
                
                # Get recent transcripts from DB or buffer?
                # Using DB is safer to get everything including what might have been missed in buffer if we cleared it
                # But for "rolling" we usually want just the new stuff.
                # Let's use the buffer we maintain in memory for simplicity and clear it after summarizing.
                
                if not self.transcript_buffer:
                    continue

                text_to_summarize = " ".join(self.transcript_buffer)
                self.transcript_buffer = []  # Clear buffer

                # Build context with documents for context-aware summary
                async with AsyncSessionLocal() as db:
                    try:
                        builder = ContextBuilder(db)
                        context = await builder.build(
                            meeting_id=UUID(meeting_id),
                            query=text_to_summarize,  # Use transcript as query for document relevance
                            config=CONTEXT_PRESETS["summary"]
                        )

                        # Add current segment to context for summarization
                        context["current_segment"] = text_to_summarize

                        # Generate summary with full context (includes documents now)
                        enhanced_summary = await self.llm_service.generate_summary_with_context(
                            context,
                            reasoning_effort="low"
                        )

                        # Format summary text with document references if available
                        summary_text = enhanced_summary.summary
                        if enhanced_summary.key_points:
                            summary_text += "\n\nKey Points:\n" + "\n".join(f"- {p}" for p in enhanced_summary.key_points)
                        if enhanced_summary.document_references:
                            summary_text += f"\n\n[Referenced: {', '.join(enhanced_summary.document_references)}]"

                    except Exception as e:
                        logger.warning(f"Context-aware summary failed, falling back to basic: {e}")
                        # Fallback to basic summary
                        summary_text = await self.llm_service.generate_summary(text_to_summarize)

                if summary_text:
                    async with AsyncSessionLocal() as db:
                        summary = Summary(
                            meeting_id=meeting_id,
                            content=summary_text,
                            start_time=self.last_summary_time,
                            end_time=datetime.now(timezone.utc)
                        )
                        db.add(summary)
                        await db.commit()
                        await db.refresh(summary)
                        
                        self.last_summary_time = datetime.now(timezone.utc)

                        # Broadcast summary
                        await manager.broadcast_to_meeting({
                            "type": "summary_update",
                            "data": {
                                "id": summary.id,
                                "content": summary.content,
                                "start_time": summary.start_time.isoformat() if summary.start_time else None,
                                "end_time": summary.end_time.isoformat() if summary.end_time else None,
                                "created_at": summary.created_at.isoformat()
                            }
                        }, meeting_id)

                        # Broadcast token usage after each summary
                        from app.services.token_service import token_service
                        try:
                            token_usage = await token_service.get_meeting_token_usage(meeting_id, db)
                            await manager.broadcast_to_meeting({
                                "type": "token_usage",
                                "data": token_usage
                            }, meeting_id)
                        except Exception as te:
                            logger.warning(f"Failed to broadcast token usage: {te}")

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Error in summarization loop: {e}", exc_info=True)

    def _is_sentence_end(self, text: str) -> bool:
        """Check if text ends with a sentence-ending punctuation."""
        text = text.rstrip()
        return text.endswith(('.', '!', '?', '...', '."', '!"', '?"'))

    async def _handle_chunk(self, chunk: AudioChunk, meeting_id: str):
        """
        Process a single audio chunk with sentence batching.
        Accumulates text until sentence boundary or timeout, then saves/broadcasts.
        Simplified: unified transcript without speaker separation.
        """
        try:
            result = await self.transcription_service.transcribe_chunk(chunk)

            if result and result.text.strip():
                # Unified speaker for all transcripts
                speaker = "meeting"

                # Accumulate text (simplified: single accumulator)
                if self.transcript_accumulator:
                    self.transcript_accumulator = self.transcript_accumulator + " " + result.text.strip()
                else:
                    self.transcript_accumulator = result.text.strip()

                # Initialize last broadcast time if needed
                now = datetime.now(timezone.utc)
                if self.last_broadcast_time is None:
                    self.last_broadcast_time = now

                # Check if we should broadcast (sentence end or timeout)
                time_since_last = (now - self.last_broadcast_time).total_seconds()

                should_broadcast = (
                    self._is_sentence_end(self.transcript_accumulator) or
                    time_since_last >= self.batch_timeout_seconds
                )

                if should_broadcast and self.transcript_accumulator.strip():
                    # Calculate offset from meeting start (not raw event loop time)
                    if self.meeting_start_loop_time is not None:
                        offset_timestamp = result.timestamp - self.meeting_start_loop_time
                    else:
                        offset_timestamp = 0.0

                    async with AsyncSessionLocal() as db:
                        transcript = Transcript(
                            meeting_id=meeting_id,
                            text=self.transcript_accumulator.strip(),
                            timestamp=offset_timestamp,
                            speaker=speaker
                        )
                        db.add(transcript)
                        await db.commit()
                        await db.refresh(transcript)

                        # Update buffer for summarization
                        self.transcript_buffer.append(self.transcript_accumulator.strip())

                        # Broadcast transcript
                        await manager.broadcast_to_meeting({
                            "type": "transcript",
                            "data": {
                                "id": str(transcript.id),
                                "text": transcript.text,
                                "timestamp": transcript.timestamp,
                                "speaker": transcript.speaker,
                                "created_at": transcript.created_at.isoformat()
                            }
                        }, meeting_id)

                        # AI: Check for questions on the batched text
                        asyncio.create_task(self._process_ai_suggestions(meeting_id, self.transcript_accumulator.strip(), db))

                    # Reset accumulator
                    self.transcript_accumulator = ""
                    self.last_broadcast_time = now

        except Exception as e:
            logger.error(f"Error handling chunk: {e}")

    async def _process_ai_suggestions(self, meeting_id: str, text: str, db_session):
        """
        Detects questions and generates suggestions using unified context.
        """
        try:
            # 1. Detect Question
            is_question = await self.llm_service.detect_question(text)
            if not is_question:
                return

            # 2. Build unified context with ContextBuilder
            async with AsyncSessionLocal() as db:
                builder = ContextBuilder(db)
                context = await builder.build(
                    meeting_id=UUID(meeting_id),
                    query=text,
                    config=CONTEXT_PRESETS["suggestion"]
                )

                # 3. Generate Suggestions with context
                try:
                    enhanced_result = await self.llm_service.generate_suggestion_with_context(
                        question=text,
                        context=context
                    )
                    suggestions = enhanced_result.suggestions
                    document_sources = enhanced_result.document_sources
                except Exception as e:
                    logger.warning(f"Context-aware suggestions failed, falling back: {e}")
                    # Fallback to basic suggestion generation
                    doc_texts = [d.text for d in context.get("documents", [])]
                    recent_context = builder.format_transcripts_only(context.get("transcripts", []))
                    suggestions = await self.llm_service.generate_suggestion(text, recent_context, doc_texts)
                    document_sources = [d.document_filename for d in context.get("documents", [])]

                if suggestions:
                    # 4. Store Suggestion with document sources
                    suggestion = Suggestion(
                        meeting_id=meeting_id,
                        question=text,
                        suggestion_text="",  # We store JSON now
                        suggestions_json=suggestions,
                        context_used=document_sources  # Now storing document filenames
                    )
                    db.add(suggestion)
                    await db.commit()
                    await db.refresh(suggestion)

                    # 5. Broadcast with document sources
                    await manager.broadcast_to_meeting({
                        "type": "suggestion_new",
                        "data": {
                            "id": suggestion.id,
                            "question": suggestion.question,
                            "suggestions": suggestion.suggestions_json,
                            "document_sources": document_sources,
                            "created_at": suggestion.created_at.isoformat()
                        }
                    }, meeting_id)

        except Exception as e:
            logger.error(f"Error in AI suggestion process: {e}", exc_info=True)

# Singleton
meeting_service = MeetingService()
