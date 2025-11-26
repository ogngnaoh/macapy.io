/**
 * MeetingView Component
 * Main container for the active meeting interface
 */

import { useEffect } from 'react';
import { useStore } from '@/store';
import { useWebSocket } from '@/hooks/useWebSocket';
import { MeetingControls } from './MeetingControls';
import { TranscriptPanel } from './TranscriptPanel';

export function MeetingView() {
  const meeting = useStore((state) => state.meeting);
  const websocket = useStore((state) => state.websocket);

  // Connect WebSocket when meeting is active
  const meetingId =
    meeting.status === 'recording' || meeting.status === 'paused'
      ? meeting.current?.id || null
      : null;

  useWebSocket(meetingId);

  // WebSocket status indicator
  const wsStatusColor = {
    connected: 'bg-accent-success',
    connecting: 'bg-accent-warning',
    disconnected: 'bg-text-dim',
    error: 'bg-accent-error',
  }[websocket.status];

  return (
    <div className="flex-1 flex flex-col min-h-0 bg-bg-primary">
      {/* Meeting Controls */}
      <MeetingControls />

      {/* WebSocket Status (only show when meeting is active) */}
      {meetingId && (
        <div className="px-4 py-1 bg-bg-secondary border-b border-border-default flex items-center gap-2">
          <div className={`w-1.5 h-1.5 rounded-full ${wsStatusColor}`} />
          <span className="text-text-dim text-xs">
            WebSocket: {websocket.status}
          </span>
        </div>
      )}

      {/* Main Content Area */}
      <div className="flex-1 flex flex-col min-h-0">
        {meeting.status === 'idle' ? (
          // Welcome / Ready state
          <div className="flex-1 flex items-center justify-center">
            <div className="text-center max-w-md px-4">
              <div className="text-4xl mb-4">🎤</div>
              <h2 className="text-text-primary text-lg font-medium mb-2">
                Ready to Start
              </h2>
              <p className="text-text-muted text-sm mb-4">
                Click "Start Meeting" to begin capturing audio and generating
                real-time transcription.
              </p>
              <div className="text-text-dim text-xs space-y-1">
                <p>
                  <kbd className="px-1.5 py-0.5 bg-bg-tertiary rounded text-text-muted">
                    Ctrl+Shift+M
                  </kbd>{' '}
                  to start meeting
                </p>
                <p>
                  <kbd className="px-1.5 py-0.5 bg-bg-tertiary rounded text-text-muted">
                    Ctrl+Shift+P
                  </kbd>{' '}
                  to pause/resume
                </p>
                <p>
                  <kbd className="px-1.5 py-0.5 bg-bg-tertiary rounded text-text-muted">
                    Ctrl+K
                  </kbd>{' '}
                  to ask AI
                </p>
              </div>
            </div>
          </div>
        ) : (
          // Active meeting - show transcript panel
          <TranscriptPanel />
        )}
      </div>
    </div>
  );
}

export default MeetingView;
