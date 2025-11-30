import { useState, useEffect } from 'react';
import { Icon } from '@/components/common';
import type { Platform } from '@/lib/platform';

interface TitleBarProps {
  platform: Platform | null;
}

export function TitleBar({ platform }: TitleBarProps) {
  const [isMaximized, setIsMaximized] = useState(false);

  useEffect(() => {
    if (window.electronAPI) {
      window.electronAPI.isMaximized().then(setIsMaximized);
      const unsubscribe = window.electronAPI.onMaximizeChange(setIsMaximized);
      return () => unsubscribe();
    }
  }, []);

  const handleMinimize = () => {
    console.log('TitleBar: Minimize clicked');
    if (window.electronAPI) {
      window.electronAPI.minimize();
    } else {
      console.error('TitleBar: electronAPI not available');
    }
  };
  const handleMaximize = () => {
    console.log('TitleBar: Maximize clicked');
    if (window.electronAPI) {
      window.electronAPI.maximize();
    } else {
      console.error('TitleBar: electronAPI not available');
    }
  };
  const handleClose = () => {
    console.log('TitleBar: Close clicked');
    if (window.electronAPI) {
      window.electronAPI.close().catch(err => console.error('TitleBar: Failed to close window:', err));
    } else {
      console.error('TitleBar: electronAPI not available');
    }
  };

  // Render macOS-style traffic lights or Windows-style buttons
  // Default to non-macOS style if platform is null (unlikely with sync detection)
  const isMacOS = platform === 'darwin';

  return (
    <div className="h-9 bg-bg-secondary border-b border-border-default flex items-center justify-between px-4 drag-region relative z-50">
      {/* macOS: Traffic lights on left */}
      {isMacOS && (
        <div className="flex items-center gap-2 no-drag">
          <button
            onClick={handleClose}
            className="w-3 h-3 rounded-full bg-[#FF5F57] hover:bg-[#FF3B30] transition-colors flex items-center justify-center group cursor-pointer"
            aria-label="Close"
            data-testid="window-close"
          >
            <svg className="w-2 h-2 text-[#4D0000] opacity-0 group-hover:opacity-100" fill="currentColor" viewBox="0 0 24 24">
              <path d="M6 18L18 6M6 6l12 12" stroke="currentColor" strokeWidth={3} strokeLinecap="round" />
            </svg>
          </button>
          <button
            onClick={handleMinimize}
            className="w-3 h-3 rounded-full bg-[#FEBC2E] hover:bg-[#F5A623] transition-colors flex items-center justify-center group cursor-pointer"
            aria-label="Minimize"
            data-testid="window-minimize"
          >
            <svg className="w-2 h-2 text-[#995700] opacity-0 group-hover:opacity-100" fill="currentColor" viewBox="0 0 24 24">
              <path d="M5 12h14" stroke="currentColor" strokeWidth={3} strokeLinecap="round" />
            </svg>
          </button>
          <button
            onClick={handleMaximize}
            className="w-3 h-3 rounded-full bg-[#28C840] hover:bg-[#1AAB29] transition-colors flex items-center justify-center group cursor-pointer"
            aria-label={isMaximized ? 'Restore' : 'Maximize'}
            data-testid="window-maximize"
          >
            <svg className="w-2 h-2 text-[#006500] opacity-0 group-hover:opacity-100" fill="currentColor" viewBox="0 0 24 24">
              {isMaximized ? (
                <path d="M8 4v4H4v12h12v-4h4V4H8z" stroke="currentColor" strokeWidth={2} />
              ) : (
                <path d="M4 4h16v16H4z" stroke="currentColor" strokeWidth={2} />
              )}
            </svg>
          </button>
        </div>
      )}

      {/* Left side - App title (no controls on Windows/Linux) */}
      {!isMacOS && (
        <div className="flex items-center gap-4 no-drag">
          <span className="text-text-primary font-bold text-sm">macapy</span>
          <span className="text-text-dim text-xs">Meeting Assistant</span>
        </div>
      )}

      {/* Center - Meeting status */}
      <div className="flex-1 flex justify-center">
        {isMacOS && (
          <div className="flex items-center gap-2">
            <span className="text-text-primary font-bold text-sm">macapy</span>
            <span className="text-text-dim text-xs">Meeting Assistant</span>
          </div>
        )}
        {!isMacOS && <span className="text-text-dim text-xs">No active meeting</span>}
      </div>

      {/* Right side - Window controls (Windows/Linux) */}
      {!isMacOS && (
        <div className="flex items-center gap-1 no-drag">
          <button
            onClick={handleMinimize}
            className="w-10 h-7 flex items-center justify-center text-text-muted hover:bg-bg-tertiary hover:text-text-primary transition-colors"
            aria-label="Minimize"
            data-testid="window-minimize"
          >
            <Icon name="minimize" size="sm" strokeWidth={2} />
          </button>
          <button
            onClick={handleMaximize}
            className="w-10 h-7 flex items-center justify-center text-text-muted hover:bg-bg-tertiary hover:text-text-primary transition-colors"
            aria-label={isMaximized ? 'Restore' : 'Maximize'}
            data-testid="window-maximize"
          >
            <Icon name={isMaximized ? 'restore' : 'maximize'} size="sm" strokeWidth={2} />
          </button>
          <button
            onClick={handleClose}
            className="w-10 h-7 flex items-center justify-center text-text-muted hover:bg-accent-error hover:text-white transition-colors"
            aria-label="Close"
            data-testid="window-close"
          >
            <Icon name="close" size="sm" strokeWidth={2} />
          </button>
        </div>
      )}
    </div>
  );
}
