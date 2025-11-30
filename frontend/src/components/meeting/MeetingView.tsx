/**
 * MeetingView Component
 * Main container for the active meeting interface
 * Includes: transcript, summaries, queries, suggestions, documents, and token usage
 */

import { useCallback } from 'react';
import { useStore } from '@/store';
import { useWebSocket } from '@/hooks/useWebSocket';
import { useToast } from '@/components/common';
import { MeetingControls } from './MeetingControls';
import { TranscriptPanel } from './TranscriptPanel';
import { AIResponsePanel } from './AIResponsePanel';
import { TokenUsageIndicator } from './TokenUsageIndicator';
import { DocumentPanel } from './DocumentPanel';
import { cn } from '@/lib/utils';
import { getModifierKey } from '@/lib/platform';

export function MeetingView() {
  const meeting = useStore((state) => state.meeting);
  const websocket = useStore((state) => state.websocket);
  const { toast } = useToast();

  // Handle WebSocket errors with toast notifications
  const handleWebSocketError = useCallback(
    (message: string, recoverable: boolean) => {
      toast({
        title: recoverable ? 'Connection Issue' : 'Error',
        description: message,
        variant: recoverable ? 'warning' : 'error',
        duration: recoverable ? 5000 : 8000,
      });
    },
    [toast]
  );

  // Connect WebSocket when meeting is active
  const meetingId =
    meeting.status === 'recording' || meeting.status === 'paused'
      ? meeting.current?.id || null
      : null;

  useWebSocket(meetingId, { onError: handleWebSocketError });

  // WebSocket status indicator
  const wsStatusColor = {
    connected: 'bg-accent-success',
    connecting: 'bg-accent-warning',
    disconnected: 'bg-text-dim',
    error: 'bg-accent-error',
  }[websocket.status];

  const isActive = meeting.status !== 'idle';
  const modKey = getModifierKey();

  return (
    <div className="flex-1 flex flex-col min-h-0 bg-bg-primary">
      {/* Meeting Controls */}
      <MeetingControls />

      {/* WebSocket Status (only show when meeting is active) */}
      {meetingId && (
        <div className="px-4 py-1 bg-bg-tertiary/50 border-b border-border-default flex items-center gap-2">
          <div className={cn('w-1.5 h-1.5 rounded-full', wsStatusColor)} />
          <span className="text-text-dim text-xs font-mono">
            {websocket.status}
          </span>
        </div>
      )}

      {/* Main Content Area */}
      <div className="flex-1 flex min-h-0">
        {!isActive ? (
          // Welcome / Ready state
          <div className="flex-1 flex items-center justify-center">
            <div className="text-center max-w-md px-4">
              <div className="text-4xl mb-4">🎤</div>
              <h2 className="text-text-primary text-lg font-medium font-mono mb-2">
                Ready to Start
              </h2>
              <p className="text-text-muted text-sm font-mono mb-6">
                Click "Start Meeting" to begin capturing audio and generating
                real-time transcription.
              </p>
              <div className="text-text-dim text-xs font-mono space-y-2 text-left inline-block">
                <p className="flex items-center gap-2">
                  <kbd className="px-1.5 py-0.5 bg-bg-tertiary border border-border-default rounded text-text-muted">
                    {modKey}+Shift+M
                  </kbd>
                  <span>Start meeting</span>
                </p>
                <p className="flex items-center gap-2">
                  <kbd className="px-1.5 py-0.5 bg-bg-tertiary border border-border-default rounded text-text-muted">
                    {modKey}+K
                  </kbd>
                  <span>Ask AI a question</span>
                </p>
                <p className="flex items-center gap-2">
                  <kbd className="px-1.5 py-0.5 bg-bg-tertiary border border-border-default rounded text-text-muted">
                    {modKey}+Shift+R
                  </kbd>
                  <span>30-second recap</span>
                </p>
                <p className="flex items-center gap-2">
                  <kbd className="px-1.5 py-0.5 bg-bg-tertiary border border-border-default rounded text-text-muted">
                    {modKey}+Shift+P
                  </kbd>
                  <span>Pause/resume</span>
                </p>
                <p className="flex items-center gap-2">
                  <kbd className="px-1.5 py-0.5 bg-bg-tertiary border border-border-default rounded text-text-muted">
                    {modKey}+H
                  </kbd>
                  <span>View history</span>
                </p>
              </div>
              {/* Blinking cursor */}
              <div className="mt-6">
                <span className="inline-block w-2 h-4 bg-text-primary animate-blink" />
              </div>
            </div>
          </div>
        ) : (
          // Active meeting - split layout
          <>
            {/* Left Panel: Transcript (60%) */}
            <div className="w-3/5 flex flex-col min-h-0 border-r border-border-default">
              <TranscriptPanel />
            </div>

            {/* Right Panel: AI Response Panel + Documents (40%) */}
            <div className="w-2/5 flex flex-col min-h-0">
              {/* AI Response Panel (summaries, suggestions, queries - unified) */}
              <div className="flex-1 min-h-0 border-b border-border-default">
                <AIResponsePanel />
              </div>

              {/* Document Panel (collapsible) */}
              <DocumentPanel />
            </div>
          </>
        )}
      </div>

      {/* Token Usage Indicator (status bar) */}
      <TokenUsageIndicator />
    </div>
  );
}

export default MeetingView;
