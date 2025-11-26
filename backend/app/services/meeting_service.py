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

class MeetingService:
    def __init__(self):
        self.audio_capture = AudioCaptureService()
        self.transcription_service = get_transcription_service()
        self.llm_service = LLMService()
        self.current_meeting_id: Optional[str] = None
        self.capture_task: Optional[asyncio.Task] = None
        self.summary_task: Optional[asyncio.Task] = None
        self.is_running = False
        self.is_paused = False  # Pause state for privacy feature

        # Buffers for AI processing
        self.transcript_buffer: List[str] = []
        self.last_summary_time = datetime.utcnow()

    async def start_meeting(self, meeting_id: str):
        """
        Start the meeting processing pipeline.
        """
        if self.is_running:
            logger.warning("Meeting already in progress")
            return

        self.current_meeting_id = meeting_id
        self.is_running = True
        self.transcript_buffer = []
        self.last_summary_time = datetime.utcnow()
        
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
        """
        logger.info("Starting audio processing loop")
        try:
            async for chunk in self.audio_capture.capture_audio():
                if not self.is_running:
                    break
                # Skip processing when paused (privacy feature)
                if self.is_paused:
                    continue
                asyncio.create_task(self._handle_chunk(chunk, meeting_id))

        except Exception as e:
            logger.error(f"Error in processing loop: {e}", exc_info=True)
        finally:
            logger.info("Audio processing loop ended")

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
                        
                        # Broadcast
                        await manager.broadcast_to_meeting({
                            "type": "summary_update",
                            "data": {
                                "id": summary.id,
                                "content": summary.content,
                                "created_at": summary.created_at.isoformat()
                            }
                        }, meeting_id)

        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Error in summarization loop: {e}", exc_info=True)

    async def _handle_chunk(self, chunk: AudioChunk, meeting_id: str):
        """
        Process a single audio chunk: Transcribe -> Save -> Broadcast -> Check for Questions
        """
        try:
            result = await self.transcription_service.transcribe_chunk(chunk)
            
            if result and result.text.strip():
                # Save to DB with speaker from audio source
                # chunk.source is "system" (loopback/others) or "user" (mic/you)
                speaker = getattr(chunk, 'source', 'unknown')
                async with AsyncSessionLocal() as db:
                    transcript = Transcript(
                        meeting_id=meeting_id,
                        text=result.text,
                        timestamp=result.timestamp,
                        speaker=speaker
                    )
                    db.add(transcript)
                    await db.commit()
                    await db.refresh(transcript)
                    
                    # Update buffer for summarization
                    self.transcript_buffer.append(result.text)
                    
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
                    # We do this in background to not block
                    asyncio.create_task(self._process_ai_suggestions(meeting_id, result.text, db))
                    
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
