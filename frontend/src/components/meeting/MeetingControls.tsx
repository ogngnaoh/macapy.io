/**
 * MeetingControls Component
 * Start/Stop/Pause/Resume controls with duration timer
 */

import { useState, useEffect, useCallback } from 'react';
import { useStore } from '@/store';
import { meetingsApi } from '@/services/api';
import { wsManager } from '@/services/websocket';
import { RecapButton } from './RecapButton';

export function MeetingControls() {
  const {
    meeting,
    setCurrentMeeting,
    setMeetingStatus,
    setMeetingDuration,
    incrementDuration,
    setMeetingError,
    resetMeeting,
    addMeetingToHistory,
    setWebSocketStatus,
  } = useStore();

  const [title, setTitle] = useState('');
  const [isEditing, setIsEditing] = useState(false);

  // Duration timer
  useEffect(() => {
    let interval: ReturnType<typeof setInterval> | null = null;

    if (meeting.status === 'recording') {
      interval = setInterval(() => {
        incrementDuration();
      }, 1000);
    }

    return () => {
      if (interval) clearInterval(interval);
    };
  }, [meeting.status, incrementDuration]);

  // WebSocket connection
  useEffect(() => {
    if (meeting.current && meeting.status === 'recording') {
      wsManager.connect(meeting.current.id);

      const unsubStatus = wsManager.onStatusChange((status) => {
        setWebSocketStatus(status);
      });

      return () => {
        unsubStatus();
        wsManager.disconnect();
      };
    }
  }, [meeting.current?.id, meeting.status, setWebSocketStatus]);

  const formatDuration = (seconds: number): string => {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    return `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  };

  const handleStart = useCallback(async () => {
    try {
      setMeetingStatus('starting');
      setMeetingError(null);

      // Create meeting
      const newMeeting = await meetingsApi.create({
        title: title || `Meeting - ${new Date().toLocaleString()}`,
      });

      setCurrentMeeting(newMeeting);

      // Start meeting (triggers audio capture)
      const startedMeeting = await meetingsApi.start(newMeeting.id);
      setCurrentMeeting(startedMeeting);
      setMeetingStatus('recording');
      setMeetingDuration(0);
    } catch (error) {
      console.error('Failed to start meeting:', error);
      setMeetingError(error instanceof Error ? error.message : 'Failed to start meeting');
      setMeetingStatus('error');
    }
  }, [title, setCurrentMeeting, setMeetingStatus, setMeetingDuration, setMeetingError]);

  const handleStop = useCallback(async () => {
    if (!meeting.current) return;

    try {
      setMeetingStatus('ending');
      const endedMeeting = await meetingsApi.end(meeting.current.id);
      wsManager.disconnect();

      // Save to history BEFORE resetting state
      addMeetingToHistory({
        ...endedMeeting,
        status: 'COMPLETED',
      });

      resetMeeting();
    } catch (error) {
      console.error('Failed to stop meeting:', error);
      setMeetingError(error instanceof Error ? error.message : 'Failed to stop meeting');
    }
  }, [meeting.current, setMeetingStatus, addMeetingToHistory, resetMeeting, setMeetingError]);

  const handlePause = useCallback(async () => {
    if (!meeting.current) return;

    try {
      await meetingsApi.pause(meeting.current.id);
      setMeetingStatus('paused');
    } catch (error) {
      console.error('Failed to pause meeting:', error);
    }
  }, [meeting.current, setMeetingStatus]);

  const handleResume = useCallback(async () => {
    if (!meeting.current) return;

    try {
      await meetingsApi.resume(meeting.current.id);
      setMeetingStatus('recording');
    } catch (error) {
      console.error('Failed to resume meeting:', error);
    }
  }, [meeting.current, setMeetingStatus]);

  const isIdle = meeting.status === 'idle';
  const isRecording = meeting.status === 'recording';
  const isPaused = meeting.status === 'paused';
  const isStarting = meeting.status === 'starting';
  const isEnding = meeting.status === 'ending';

  return (
    <div className="px-4 py-3 bg-bg-secondary border-b border-border-default">
      <div className="flex items-center justify-between gap-4">
        {/* Title / Status */}
        <div className="flex-1 min-w-0">
          {isIdle ? (
            <div className="flex items-center gap-2">
              <span className="text-text-dim">&gt;</span>
              <input
                type="text"
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                placeholder="Meeting title (optional)"
                className="flex-1 bg-transparent border-none outline-none text-text-primary placeholder:text-text-dim text-sm font-mono"
              />
            </div>
          ) : (
            <div className="flex items-center gap-3">
              {/* Recording indicator */}
              <div className="flex items-center gap-2">
                {isRecording && (
                  <span className="w-2 h-2 bg-accent-error rounded-full animate-pulse" />
                )}
                {isPaused && (
                  <span className="text-accent-warning text-xs">[PAUSED]</span>
                )}
                <span className="text-text-primary text-sm font-medium truncate">
                  {meeting.current?.title || 'Untitled Meeting'}
                </span>
              </div>
            </div>
          )}
        </div>

        {/* Duration Timer */}
        {!isIdle && (
          <div className="flex items-center gap-2">
            <span className="text-text-muted text-xs font-mono">
              {formatDuration(meeting.duration)}
            </span>
          </div>
        )}

        {/* Controls */}
        <div className="flex items-center gap-3">
          {/* Recap Button (only when meeting is active) */}
          {!isIdle && <RecapButton />}

          {isIdle && (
            <button
              data-testid="meeting-start-btn"
              onClick={handleStart}
              disabled={isStarting}
              className="px-4 py-1.5 bg-text-primary text-bg-primary text-sm font-medium rounded hover:bg-text-secondary transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            >
              {isStarting ? 'Starting...' : 'Start Meeting'}
            </button>
          )}

          {isRecording && (
            <>
              <button
                data-testid="meeting-pause-btn"
                onClick={handlePause}
                className="px-3 py-1.5 bg-bg-tertiary text-accent-warning text-sm font-medium rounded hover:bg-border-default transition-colors"
              >
                Pause
              </button>
              <button
                data-testid="meeting-stop-btn"
                onClick={handleStop}
                className="px-3 py-1.5 bg-accent-error/20 text-accent-error text-sm font-medium rounded hover:bg-accent-error/30 transition-colors"
              >
                End Meeting
              </button>
            </>
          )}

          {isPaused && (
            <>
              <button
                onClick={handleResume}
                className="px-3 py-1.5 bg-accent-success/20 text-accent-success text-sm font-medium rounded hover:bg-accent-success/30 transition-colors"
              >
                Resume
              </button>
              <button
                onClick={handleStop}
                disabled={isEnding}
                className="px-3 py-1.5 bg-accent-error/20 text-accent-error text-sm font-medium rounded hover:bg-accent-error/30 transition-colors disabled:opacity-50"
              >
                {isEnding ? 'Ending...' : 'End Meeting'}
              </button>
            </>
          )}
        </div>
      </div>

      {/* Error message */}
      {meeting.error && (
        <div className="mt-2 text-accent-error text-xs">
          Error: {meeting.error}
        </div>
      )}
    </div>
  );
}

export default MeetingControls;
