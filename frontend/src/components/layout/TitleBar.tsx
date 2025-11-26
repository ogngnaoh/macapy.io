import { useState, useEffect } from 'react';
import { clsx } from 'clsx';

interface TitleBarProps {
  platform: NodeJS.Platform | null;
}

export function TitleBar({ platform }: TitleBarProps) {
  const [isMaximized, setIsMaximized] = useState(false);

  useEffect(() => {
    if (window.electronAPI) {
      window.electronAPI.isMaximized().then(setIsMaximized);
      window.electronAPI.onMaximizeChange(setIsMaximized);
    }
  }, []);

  const handleMinimize = () => window.electronAPI?.minimize();
  const handleMaximize = () => window.electronAPI?.maximize();
  const handleClose = () => window.electronAPI?.close();

  // On macOS, traffic lights are handled natively
  const showWindowControls = platform !== 'darwin';

  return (
    <div className="h-9 bg-bg-secondary border-b border-border-default flex items-center justify-between px-4 drag-region">
      {/* Left side - App title and menu */}
      <div className="flex items-center gap-4 no-drag">
        <span className="text-text-primary font-bold text-sm">macapy</span>
        <span className="text-text-dim text-xs">Meeting Assistant</span>
      </div>

      {/* Center - Meeting status (placeholder) */}
      <div className="flex-1 flex justify-center">
        <span className="text-text-dim text-xs">No active meeting</span>
      </div>

      {/* Right side - Window controls (Windows/Linux only) */}
      {showWindowControls && (
        <div className="flex items-center gap-1 no-drag">
          <button
            onClick={handleMinimize}
            className="w-10 h-7 flex items-center justify-center text-text-muted hover:bg-bg-tertiary hover:text-text-primary transition-colors"
            aria-label="Minimize"
          >
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M20 12H4" />
            </svg>
          </button>
          <button
            onClick={handleMaximize}
            className="w-10 h-7 flex items-center justify-center text-text-muted hover:bg-bg-tertiary hover:text-text-primary transition-colors"
            aria-label={isMaximized ? 'Restore' : 'Maximize'}
          >
            {isMaximized ? (
              <svg className="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <rect x="5" y="9" width="10" height="10" strokeWidth={2} rx="1" />
                <path strokeWidth={2} d="M9 9V5h10v10h-4" />
              </svg>
            ) : (
              <svg className="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <rect x="4" y="4" width="16" height="16" strokeWidth={2} rx="1" />
              </svg>
            )}
          </button>
          <button
            onClick={handleClose}
            className="w-10 h-7 flex items-center justify-center text-text-muted hover:bg-accent-error hover:text-white transition-colors"
            aria-label="Close"
          >
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
      )}
    </div>
  );
}
