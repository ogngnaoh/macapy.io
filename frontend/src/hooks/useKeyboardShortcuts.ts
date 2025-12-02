/**
 * useKeyboardShortcuts Hook
 * Global keyboard shortcut handler for the application
 */

import { useEffect, useCallback } from 'react';
import { useStore } from '@/store';
import { meetingsApi, aiApi } from '@/services/api';
import { wsManager } from '@/services/websocket';

interface ShortcutHandler {
  key: string;
  modifiers: {
    ctrl?: boolean;
    shift?: boolean;
    alt?: boolean;
    meta?: boolean;
  };
  action: () => void | Promise<void>;
  description: string;
}

export function useKeyboardShortcuts() {
  const {
    meeting,
    ui,
    suggestion,
    setCurrentMeeting,
    setMeetingStatus,
    setMeetingDuration,
    setMeetingError,
    resetMeeting,
    setActiveView,
    setAlwaysOnTop,
    dismissActiveSuggestion,
    setWebSocketStatus,
  } = useStore();

  // Start meeting handler
  const handleStartMeeting = useCallback(async () => {
    if (meeting.status !== 'idle') return;

    try {
      setMeetingStatus('starting');
      setMeetingError(null);

      const newMeeting = await meetingsApi.create({
        title: `Meeting - ${new Date().toLocaleString()}`,
      });

      setCurrentMeeting(newMeeting);

      const startedMeeting = await meetingsApi.start(newMeeting.id);
      setCurrentMeeting(startedMeeting);
      setMeetingStatus('recording');
      setMeetingDuration(0);
    } catch (error) {
      console.error('Failed to start meeting:', error);
      setMeetingError(error instanceof Error ? error.message : 'Failed to start meeting');
      setMeetingStatus('error');
    }
  }, [meeting.status, setCurrentMeeting, setMeetingStatus, setMeetingDuration, setMeetingError]);

  // End meeting handler
  const handleEndMeeting = useCallback(async () => {
    if (!meeting.current || meeting.status === 'idle') return;

    try {
      setMeetingStatus('ending');
      await meetingsApi.end(meeting.current.id);
      wsManager.disconnect();
      resetMeeting();
    } catch (error) {
      console.error('Failed to end meeting:', error);
      setMeetingError(error instanceof Error ? error.message : 'Failed to end meeting');
    }
  }, [meeting.current, meeting.status, setMeetingStatus, resetMeeting, setMeetingError]);

  // Pause/Resume toggle
  const handleTogglePause = useCallback(async () => {
    if (!meeting.current) return;

    try {
      if (meeting.status === 'recording') {
        await meetingsApi.pause(meeting.current.id);
        setMeetingStatus('paused');
      } else if (meeting.status === 'paused') {
        await meetingsApi.resume(meeting.current.id);
        setMeetingStatus('recording');
      }
    } catch (error) {
      console.error('Failed to toggle pause:', error);
    }
  }, [meeting.current, meeting.status, setMeetingStatus]);

  // Focus query input
  const handleFocusQuery = useCallback(() => {
    const queryInput = document.querySelector('[data-testid="query-input"]') as HTMLInputElement;
    queryInput?.focus();
  }, []);

  // 30-second recap (trigger via button click)
  const handleRecap = useCallback(async () => {
    // Find and click the recap button
    const recapButton = document.querySelector('button[title*="recap"]') as HTMLButtonElement;
    recapButton?.click();
  }, []);

  // Toggle history view
  const handleToggleHistory = useCallback(() => {
    setActiveView(ui.activeView === 'history' ? 'meeting' : 'history');
  }, [ui.activeView, setActiveView]);

  // Toggle always on top
  const handleToggleAlwaysOnTop = useCallback(() => {
    const newValue = !ui.isAlwaysOnTop;
    setAlwaysOnTop(newValue);

    // Call Electron IPC if available
    if (window.electronAPI?.setAlwaysOnTop) {
      window.electronAPI.setAlwaysOnTop(newValue);
    }
  }, [ui.isAlwaysOnTop, setAlwaysOnTop]);

  // Dismiss suggestion
  const handleDismissSuggestion = useCallback(() => {
    if (suggestion.active) {
      dismissActiveSuggestion();
    }
  }, [suggestion.active, dismissActiveSuggestion]);

  // Define shortcuts
  const shortcuts: ShortcutHandler[] = [
    {
      key: 'm',
      modifiers: { meta: true, shift: true },
      action: handleStartMeeting,
      description: 'Start meeting',
    },
    {
      key: 'e',
      modifiers: { meta: true, shift: true },
      action: handleEndMeeting,
      description: 'End meeting',
    },
    {
      key: 'k',
      modifiers: { meta: true },
      action: handleFocusQuery,
      description: 'Focus query input',
    },
    {
      key: 'r',
      modifiers: { meta: true, shift: true },
      action: handleRecap,
      description: '30-second recap',
    },
    {
      key: 'h',
      modifiers: { meta: true },
      action: handleToggleHistory,
      description: 'Toggle history',
    },
    {
      key: 't',
      modifiers: { meta: true, shift: true },
      action: handleToggleAlwaysOnTop,
      description: 'Toggle always on top',
    },
    {
      key: 'p',
      modifiers: { meta: true, shift: true },
      action: handleTogglePause,
      description: 'Pause/resume meeting',
    },
    {
      key: 'Escape',
      modifiers: {},
      action: handleDismissSuggestion,
      description: 'Dismiss suggestion',
    },
  ];

  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Check if we're in an input field
      const target = e.target as HTMLElement;
      const isInput = target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable;

      for (const shortcut of shortcuts) {
        const keyMatch = e.key.toLowerCase() === shortcut.key.toLowerCase();
        const ctrlMatch = (e.ctrlKey || e.metaKey) === (shortcut.modifiers.ctrl || shortcut.modifiers.meta || false);
        const shiftMatch = e.shiftKey === (shortcut.modifiers.shift || false);
        const altMatch = e.altKey === (shortcut.modifiers.alt || false);

        if (keyMatch && ctrlMatch && shiftMatch && altMatch) {
          // Allow Escape in inputs
          if (isInput && shortcut.key !== 'Escape' && !shortcut.modifiers.meta && !shortcut.modifiers.ctrl) {
            continue;
          }

          e.preventDefault();
          shortcut.action();
          return;
        }
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [shortcuts]);

  return { shortcuts };
}



export default useKeyboardShortcuts;
