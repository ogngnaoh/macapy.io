/**
 * useWebSocket Hook
 * Manages WebSocket connection and dispatches events to store
 */

import { useEffect, useCallback, useRef } from 'react';
import { useStore } from '@/store';
import { wsManager, type WebSocketEvent } from '@/services/websocket';

interface UseWebSocketOptions {
  onError?: (message: string, recoverable: boolean) => void;
}

export function useWebSocket(meetingId: string | null, options: UseWebSocketOptions = {}) {
  const {
    addTranscript,
    addSummary,
    addSuggestion,
    addAIResponse,
    setTokenUsage,
    setMeetingStatus,
    setWebSocketStatus,
  } = useStore();

  // Use ref for callback to avoid dependency changes
  const onErrorRef = useRef(options.onError);
  onErrorRef.current = options.onError;

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
            start_time: event.data.start_time ?? null,
            end_time: event.data.end_time ?? null,
            created_at: event.data.created_at,
          });
          // Also add to unified AI responses
          addAIResponse({
            id: `summary-${event.data.id}`,
            type: 'summary',
            content: event.data.content,
            timestamp: event.data.created_at,
            metadata: {
              timeRange: {
                start: event.data.start_time ?? null,
                end: event.data.end_time ?? null,
              },
            },
          });
          break;

        case 'suggestion_new':
          addSuggestion({
            id: event.data.id,
            question: event.data.question,
            suggestions: event.data.suggestions,
            created_at: event.data.created_at,
          });
          // Also add to unified AI responses
          addAIResponse({
            id: `suggestion-${event.data.id}`,
            type: 'suggestion',
            content: event.data.question,
            timestamp: event.data.created_at,
            metadata: {
              question: event.data.question,
              suggestions: event.data.suggestions,
            },
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
          onErrorRef.current?.(
            event.data.message || 'WebSocket error occurred',
            event.data.recoverable ?? false
          );
          break;

        default:
          console.warn('[WS] Unknown event type:', event);
      }
    },
    [addTranscript, addSummary, addSuggestion, addAIResponse, setTokenUsage, setMeetingStatus, meetingId]
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
