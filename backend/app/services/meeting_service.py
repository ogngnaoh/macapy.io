import asyncio
import logging
from typing import Optional, List
from datetime import datetime, timedelta

from app.services.audio_capture import AudioCaptureService, AudioChunk
from app.services.transcription import get_transcription_service, TranscriptionService
from app.services.websocket_manager import manager
from app.services.llm_service import LLMService
from app.services.context_service import ContextService
from app.db.session import AsyncSessionLocal
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

        # Buffers for AI processing
        self.transcript_buffer: List[str] = []
        self.last_summary_time = datetime.utcnow()

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
        self.last_summary_time = datetime.utcnow()

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
                meeting.end_time = datetime.utcnow()
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
        logger.info(f"Starting Realtime API processing for meeting {meeting_id}")

        try:
            # Initialize Realtime API service
            self.realtime_service = get_realtime_transcription_service()

            # Connect to Realtime API
            connected = await self.realtime_service.connect()
            if not connected:
                logger.warning("Failed to connect to Realtime API, falling back to Whisper")
                self.use_realtime = False
                await self._processing_loop_whisper(meeting_id)
                return

            logger.info("Connected to Realtime API, starting transcript receiver")
            # Start task to receive transcripts
            self.realtime_task = asyncio.create_task(
                self._handle_realtime_transcripts(meeting_id)
            )

            # Send audio chunks to Realtime API
            chunk_count = 0
            async for chunk in self.audio_capture.capture_audio():
                if not self.is_running:
                    break

                # Skip processing when paused (privacy feature)
                if self.is_paused:
                    continue

                chunk_count += 1
                if chunk_count % 100 == 1:  # Log every 100th chunk
                    logger.debug(f"Sending audio chunk #{chunk_count}")

                # Resample to 24kHz if needed
                if chunk.sample_rate != settings.REALTIME_SAMPLE_RATE:
                    audio_24k = resample_to_24khz(chunk.data, chunk.sample_rate)
                else:
                    audio_24k = chunk.data

                # Send to Realtime API
                await self.realtime_service.send_audio_numpy(audio_24k)

        except Exception as e:
            logger.error(f"Error in Realtime processing loop: {e}", exc_info=True)
            # Attempt fallback to Whisper
            if self.is_running:
                logger.info("Attempting fallback to Whisper API")
                self.use_realtime = False
                await self._processing_loop_whisper(meeting_id)

        finally:
            # Cleanup Realtime API
            if self.realtime_task:
                self.realtime_task.cancel()
                try:
                    await self.realtime_task
                except asyncio.CancelledError:
                    pass

            if self.realtime_service:
                await self.realtime_service.close()
                self.realtime_service = None

            logger.info("Realtime processing loop ended")

    async def _handle_realtime_transcripts(self, meeting_id: str):
        """Handle streaming transcripts from Realtime API."""
        logger.debug(f"Transcript handler started for meeting {meeting_id}")
        if not self.realtime_service:
            logger.warning("No realtime_service, exiting handler")
            return

        try:
            async for transcript in self.realtime_service.receive_transcripts():
                logger.debug(f"Received transcript: final={transcript.is_final}, text='{transcript.text[:30] if transcript.text else ''}...'")
                if not self.is_running:
                    break

                if self.is_paused:
                    continue

                # Only process final transcripts (complete sentences)
                # Realtime API with VAD provides natural sentence boundaries
                if transcript.is_final and transcript.text.strip():
                    await self._handle_realtime_transcript(
                        transcript.text.strip(),
                        transcript.timestamp,
                        meeting_id
                    )

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Error handling Realtime transcripts: {e}")

    async def _handle_realtime_transcript(self, text: str, timestamp: float, meeting_id: str):
        """Save and broadcast a transcript from Realtime API."""
        try:
            # Unified transcript - no speaker separation needed
            # LLM orchestration focuses on content, not speaker attribution
            speaker = "meeting"

            async with AsyncSessionLocal() as db:
                transcript = Transcript(
                    meeting_id=meeting_id,
                    text=text,
                    timestamp=timestamp,
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
                self.transcript_buffer = [] # Clear buffer
                
                # Generate summary
                summary_text = await self.llm_service.generate_summary(text_to_summarize)
                
                if summary_text:
                    async with AsyncSessionLocal() as db:
                        summary = Summary(
                            meeting_id=meeting_id,
                            content=summary_text,
                            start_time=self.last_summary_time,
                            end_time=datetime.utcnow()
                        )
                        db.add(summary)
                        await db.commit()
                        await db.refresh(summary)
                        
                        self.last_summary_time = datetime.utcnow()
                        
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
                now = datetime.utcnow()
                if self.last_broadcast_time is None:
                    self.last_broadcast_time = now

                # Check if we should broadcast (sentence end or timeout)
                time_since_last = (now - self.last_broadcast_time).total_seconds()

                should_broadcast = (
                    self._is_sentence_end(self.transcript_accumulator) or
                    time_since_last >= self.batch_timeout_seconds
                )

                if should_broadcast and self.transcript_accumulator.strip():
                    async with AsyncSessionLocal() as db:
                        transcript = Transcript(
                            meeting_id=meeting_id,
                            text=self.transcript_accumulator.strip(),
                            timestamp=result.timestamp,
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
        Detects questions and generates suggestions.
        """
        try:
            # 1. Detect Question
            is_question = await self.llm_service.detect_question(text)
            if not is_question:
                return

            # 2. Retrieve Context
            # We need a fresh session for async operations if the passed one is closed or busy?
            # Actually passed session `db` from _handle_chunk is closed after the block.
            # So we create a new one.
            async with AsyncSessionLocal() as db:
                context_service = ContextService(db)
                relevant_chunks = await context_service.retrieve_relevant_context(meeting_id, text)
                
                # 3. Generate Suggestions
                # We need recent transcript context too. 
                # Let's grab the last few transcripts from DB.
                # For now, just use the current text as "recent conversation" + maybe buffer?
                # A proper implementation would query the last N transcripts.
                recent_context = " ".join(self.transcript_buffer[-5:]) # Last 5 chunks from buffer
                
                suggestions = await self.llm_service.generate_suggestion(text, recent_context, relevant_chunks)
                
                if suggestions:
                    # 4. Store Suggestion
                    suggestion = Suggestion(
                        meeting_id=meeting_id,
                        question=text,
                        suggestion_text="", # We store JSON now
                        suggestions_json=suggestions,
                        context_used=relevant_chunks # Storing text for now, ideally IDs
                    )
                    db.add(suggestion)
                    await db.commit()
                    await db.refresh(suggestion)
                    
                    # 5. Broadcast
                    await manager.broadcast_to_meeting({
                        "type": "suggestion_new",
                        "data": {
                            "id": suggestion.id,
                            "question": suggestion.question,
                            "suggestions": suggestion.suggestions_json,
                            "created_at": suggestion.created_at.isoformat()
                        }
                    }, meeting_id)

        except Exception as e:
            logger.error(f"Error in AI suggestion process: {e}")

# Singleton
meeting_service = MeetingService()
