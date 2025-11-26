import { useState, useEffect } from 'react';
import { TitleBar } from '@/components/layout/TitleBar';
import { Sidebar } from '@/components/layout/Sidebar';
import { MeetingView } from '@/components/meeting';
import { useStore, selectUI, selectMeeting, selectWebSocket } from '@/store';

function App() {
  const [platform, setPlatform] = useState<NodeJS.Platform | null>(null);
  const ui = useStore(selectUI);
  const meeting = useStore(selectMeeting);
  const websocket = useStore(selectWebSocket);

  useEffect(() => {
    // Get platform info from Electron
    if (window.electronAPI) {
      window.electronAPI.getPlatform().then(setPlatform);
    }
  }, []);

  // Status bar info
  const statusText = (() => {
    if (meeting.status === 'recording') return 'Recording...';
    if (meeting.status === 'paused') return 'Paused';
    if (meeting.status === 'starting') return 'Starting...';
    if (meeting.status === 'ending') return 'Ending...';
    return 'Ready';
  })();

  return (
    <div className="flex flex-col h-screen bg-bg-primary text-text-primary font-mono overflow-hidden">
      {/* Custom title bar for frameless window */}
      <TitleBar platform={platform} />

      {/* Main application layout */}
      <div className="flex flex-1 overflow-hidden">
        {/* Sidebar navigation */}
        {!ui.isCompactMode && <Sidebar />}

        {/* Main content area */}
        <main className="flex-1 flex flex-col min-w-0 min-h-0">
          {ui.activeView === 'meeting' ? (
            <MeetingView />
          ) : (
            // History view placeholder
            <div className="flex-1 flex items-center justify-center">
              <span className="text-text-muted">History view coming soon...</span>
            </div>
          )}
        </main>
      </div>

      {/* Status bar */}
      <div className="h-6 bg-bg-tertiary border-t border-border-default px-4 flex items-center justify-between text-xs text-text-dim">
        <div className="flex items-center gap-4">
          <span>macapy v0.1.0</span>
          {meeting.current && (
            <span className="text-text-muted">
              Meeting: {meeting.current.title || 'Untitled'}
            </span>
          )}
        </div>
        <div className="flex items-center gap-4">
          <span
            className={
              meeting.status === 'recording'
                ? 'text-accent-success'
                : meeting.status === 'paused'
                ? 'text-accent-warning'
                : 'text-text-dim'
            }
          >
            {statusText}
          </span>
          {websocket.status !== 'disconnected' && (
            <span className="flex items-center gap-1">
              <span
                className={`w-1.5 h-1.5 rounded-full ${
                  websocket.status === 'connected'
                    ? 'bg-accent-success'
                    : 'bg-accent-warning'
                }`}
              />
              WS
            </span>
          )}
        </div>
      </div>
    </div>
  );
}

export default App;
