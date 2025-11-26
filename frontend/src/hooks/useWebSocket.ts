/**
 * useWebSocket Hook
 * Manages WebSocket connection and dispatches events to store
 */

import { useEffect, useCallback } from 'react';
import { useStore } from '@/store';
import { wsManager, type WebSocketEvent } from '@/services/websocket';

export function useWebSocket(meetingId: string | null) {
  const {
    addTranscript,
    addSummary,
    addSuggestion,
    setTokenUsage,
    setMeetingStatus,
    setWebSocketStatus,
  } = useStore();

  const handleEvent = useCallback(
    (event: WebSocketEvent) => {
      switch (event.type) {
        case 'transcript':
          addTranscript({
            id: event.data.id,
            text: event.data.text,
            timestamp: event.data.timestamp,
            speaker: event.data.speaker,
            created_at: event.data.created_at,
          });
          break;

        case 'summary_update':
          addSummary({
            id: event.data.id,
            meeting_id: meetingId || '',
            content: event.data.content,
            start_time: null,
            end_time: null,
            created_at: event.data.created_at,
          });
          break;

        case 'suggestion_new':
          addSuggestion({
            id: event.data.id,
            question: event.data.question,
            suggestions: event.data.suggestions,
            created_at: event.data.created_at,
          });
          break;

        case 'token_usage':
          setTokenUsage(event.data.current_tokens, event.data.max_tokens);
          break;

        case 'meeting_status':
          if (event.data.status === 'paused') {
            setMeetingStatus('paused');
          } else if (event.data.status === 'recording') {
            setMeetingStatus('recording');
          }
          break;

        case 'error':
          console.error('[WS] Error event:', event.data);
          // Could show toast notification here
          break;

        default:
          console.warn('[WS] Unknown event type:', event);
      }
    },
    [addTranscript, addSummary, addSuggestion, setTokenUsage, setMeetingStatus, meetingId]
  );

  useEffect(() => {
    if (!meetingId) {
      wsManager.disconnect();
      setWebSocketStatus('disconnected');
      return;
    }

    // Connect to WebSocket
    wsManager.connect(meetingId);

    // Subscribe to events
    const unsubscribe = wsManager.subscribe(handleEvent);

    // Subscribe to status changes
    const unsubscribeStatus = wsManager.onStatusChange(setWebSocketStatus);

    return () => {
      unsubscribe();
      unsubscribeStatus();
      wsManager.disconnect();
    };
  }, [meetingId, handleEvent, setWebSocketStatus]);

  return {
    status: wsManager.getStatus(),
    reconnect: () => wsManager.reconnect(),
  };
}

export default useWebSocket;
