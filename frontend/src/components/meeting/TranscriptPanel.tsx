/**
 * TranscriptPanel Component
 * Two-column transcript display (System Audio | User Audio)
 * Fixed 50/50 split as per user preference
 */

import { useRef, useEffect } from 'react';
import { useStore, selectTranscript } from '@/store';
import type { TranscriptSegment } from '@/store';

interface TranscriptItemProps {
  segment: TranscriptSegment;
  isSystem: boolean;
}

function TranscriptItem({ segment, isSystem }: TranscriptItemProps) {
  const formatTimestamp = (seconds: number): string => {
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
  };

  return (
    <div
      className={`p-2 border-l-2 ${
        isSystem ? 'border-text-primary' : 'border-accent-success'
      } bg-bg-tertiary/50 rounded-r mb-2`}
    >
      <div className="flex items-center gap-2 mb-1">
        <span className="text-text-dim text-xs font-mono">
          {formatTimestamp(segment.timestamp)}
        </span>
        <span
          className={`text-xs px-1.5 py-0.5 rounded ${
            isSystem
              ? 'bg-text-primary/20 text-text-primary'
              : 'bg-accent-success/20 text-accent-success'
          }`}
        >
          {isSystem ? 'SYSTEM' : 'YOU'}
        </span>
      </div>
      <p className="text-text-primary text-sm leading-relaxed">{segment.text}</p>
    </div>
  );
}

interface TranscriptColumnProps {
  title: string;
  segments: TranscriptSegment[];
  isSystem: boolean;
  emptyMessage: string;
  autoScroll: boolean;
}

function TranscriptColumn({
  title,
  segments,
  isSystem,
  emptyMessage,
  autoScroll,
}: TranscriptColumnProps) {
  const scrollRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom when new segments arrive
  useEffect(() => {
    if (autoScroll && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [segments.length, autoScroll]);

  return (
    <div className="flex-1 flex flex-col min-w-0 h-full">
      {/* Column Header */}
      <div
        className={`px-3 py-2 border-b ${
          isSystem ? 'border-text-primary/30' : 'border-accent-success/30'
        } flex items-center gap-2`}
      >
        <div
          className={`w-2 h-2 rounded-full ${
            isSystem ? 'bg-text-primary' : 'bg-accent-success'
          }`}
        />
        <span className="text-text-muted text-xs font-medium uppercase tracking-wider">
          {title}
        </span>
        <span className="text-text-dim text-xs ml-auto">
          {segments.length} segments
        </span>
      </div>

      {/* Scrollable Content */}
      <div
        ref={scrollRef}
        className="flex-1 overflow-y-auto p-3 space-y-1 custom-scrollbar"
      >
        {segments.length === 0 ? (
          <div className="flex items-center justify-center h-full">
            <span className="text-text-dim text-sm italic">{emptyMessage}</span>
          </div>
        ) : (
          segments.map((segment) => (
            <TranscriptItem key={segment.id} segment={segment} isSystem={isSystem} />
          ))
        )}
      </div>
    </div>
  );
}

export function TranscriptPanel() {
  const transcript = useStore(selectTranscript);
  const meeting = useStore((state) => state.meeting);
  const setAutoScroll = useStore((state) => state.setAutoScroll);

  const isActive = meeting.status === 'recording' || meeting.status === 'paused';

  // Handle manual scroll to disable auto-scroll
  const handleScroll = () => {
    if (transcript.isAutoScroll) {
      setAutoScroll(false);
    }
  };

  const handleResumeAutoScroll = () => {
    setAutoScroll(true);
  };

  return (
    <div className="flex-1 flex flex-col bg-bg-primary min-h-0">
      {/* Panel Header */}
      <div className="px-4 py-2 border-b border-border-default flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="text-text-muted text-sm">Transcript</span>
          {isActive && (
            <span className="text-accent-success text-xs">[LIVE]</span>
          )}
        </div>

        {!transcript.isAutoScroll && (
          <button
            onClick={handleResumeAutoScroll}
            className="text-xs text-text-primary hover:text-text-secondary transition-colors"
          >
            Resume auto-scroll ↓
          </button>
        )}
      </div>

      {/* Two-Column Layout (Fixed 50/50 split) */}
      <div className="flex-1 flex min-h-0" onScroll={handleScroll}>
        {/* System Audio Column (Left) - What others say */}
        <div className="w-1/2 border-r border-border-default flex flex-col">
          <TranscriptColumn
            title="System Audio"
            segments={transcript.systemSegments}
            isSystem={true}
            emptyMessage="Waiting for meeting audio..."
            autoScroll={transcript.isAutoScroll}
          />
        </div>

        {/* User Audio Column (Right) - What you say */}
        <div className="w-1/2 flex flex-col">
          <TranscriptColumn
            title="Your Audio"
            segments={transcript.userSegments}
            isSystem={false}
            emptyMessage="Waiting for your microphone..."
            autoScroll={transcript.isAutoScroll}
          />
        </div>
      </div>

      {/* Total count footer */}
      <div className="px-4 py-1.5 border-t border-border-default bg-bg-secondary">
        <span className="text-text-dim text-xs">
          Total: {transcript.systemSegments.length + transcript.userSegments.length} segments
        </span>
      </div>
    </div>
  );
}

export default TranscriptPanel;
