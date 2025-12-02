/**
 * TranscriptPanel Component
 * Unified single-column transcript display
 * All meeting audio shown in chronological order
 */

import { useRef, useEffect } from 'react';
import { useStore, selectTranscript } from '@/store';
import type { TranscriptSegment } from '@/store';

interface TranscriptItemProps {
  segment: TranscriptSegment;
}

function TranscriptItem({ segment }: TranscriptItemProps) {
  const formatTimestamp = (seconds: number): string => {
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  };

  return (
    <div className="group px-4 py-3 hover:bg-bg-tertiary/30 transition-colors border-b border-border-default/50">
      <div className="flex items-start gap-3">
        {/* Timestamp */}
        <span className="text-text-dim text-xs font-mono shrink-0 pt-0.5 opacity-60 group-hover:opacity-100 transition-opacity">
          {formatTimestamp(segment.timestamp)}
        </span>
        {/* Transcript text */}
        <p className="text-text-primary text-sm leading-relaxed flex-1">
          {segment.text}
        </p>
      </div>
    </div>
  );
}

export function TranscriptPanel() {
  const transcript = useStore(selectTranscript);
  const meeting = useStore((state) => state.meeting);
  const setAutoScroll = useStore((state) => state.setAutoScroll);
  const scrollRef = useRef<HTMLDivElement>(null);

  const isActive = meeting.status === 'recording' || meeting.status === 'paused';
  const isPaused = meeting.status === 'paused';

  // Auto-scroll to bottom when new segments arrive
  useEffect(() => {
    if (transcript.isAutoScroll && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [transcript.segments.length, transcript.isAutoScroll]);

  // Handle manual scroll to disable auto-scroll
  const handleScroll = () => {
    if (transcript.isAutoScroll && scrollRef.current) {
      const { scrollTop, scrollHeight, clientHeight } = scrollRef.current;
      // Only disable if user scrolled up significantly
      if (scrollHeight - scrollTop - clientHeight > 100) {
        setAutoScroll(false);
      }
    }
  };

  const handleResumeAutoScroll = () => {
    setAutoScroll(true);
  };

  return (
    <div data-testid="transcript-panel" className="flex-1 flex flex-col bg-bg-primary min-h-0">
      {/* Panel Header */}
      <div className="px-4 py-2.5 border-b border-border-default flex items-center justify-between bg-bg-secondary/50">
        <div className="flex items-center gap-3">
          <span className="text-text-muted text-sm font-medium">Transcript</span>
          {isActive && (
            <div className="flex items-center gap-1.5">
              <span
                className={`w-2 h-2 rounded-full ${
                  isPaused ? 'bg-accent-warning' : 'bg-accent-success animate-pulse'
                }`}
              />
              <span
                className={`text-xs ${
                  isPaused ? 'text-accent-warning' : 'text-accent-success'
                }`}
              >
                {isPaused ? 'PAUSED' : 'LIVE'}
              </span>
            </div>
          )}
        </div>

        <div className="flex items-center gap-3">
          {!transcript.isAutoScroll && (
            <button
              onClick={handleResumeAutoScroll}
              className="text-xs text-text-primary hover:text-accent-primary transition-colors flex items-center gap-1"
            >
              <span>↓</span>
              <span>Resume scroll</span>
            </button>
          )}
          <span className="text-text-dim text-xs">
            {transcript.segments.length} segments
          </span>
        </div>
      </div>

      {/* Scrollable Transcript List */}
      <div
        ref={scrollRef}
        className="flex-1 overflow-y-auto custom-scrollbar"
        onScroll={handleScroll}
      >
        {transcript.segments.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full text-center px-8">
            <div className="w-12 h-12 rounded-full bg-bg-tertiary flex items-center justify-center mb-4">
              <span className="text-2xl opacity-40">🎤</span>
            </div>
            <span className="text-text-dim text-sm">
              {isActive
                ? 'Listening for audio...'
                : 'Start a meeting to begin transcription'}
            </span>
            <span className="text-text-dim/60 text-xs mt-2">
              All meeting audio will appear here in real-time
            </span>
          </div>
        ) : (
          <div className="py-2">
            {transcript.segments.map((segment) => (
              <TranscriptItem key={segment.id} segment={segment} />
            ))}
          </div>
        )}
      </div>

      {/* Footer with live indicator */}
      {isActive && transcript.segments.length > 0 && (
        <div className="px-4 py-2 border-t border-border-default bg-bg-secondary/30">
          <div className="flex items-center gap-2 text-text-dim text-xs">
            <span className="w-1.5 h-1.5 rounded-full bg-accent-success animate-pulse" />
            <span>Transcribing meeting audio...</span>
          </div>
        </div>
      )}
    </div>
  );
}

export default TranscriptPanel;
