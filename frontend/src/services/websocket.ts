/**
 * WebSocket Manager for real-time updates
 * Connects to: ws://localhost:8000/ws/meeting/{meetingId}
 */

const WS_BASE = 'ws://localhost:8000';

export type WebSocketStatus = 'disconnected' | 'connecting' | 'connected' | 'error';

// Event types from backend
export interface TranscriptEvent {
  type: 'transcript';
  data: {
    id: string;
    text: string;
    timestamp: number;
    speaker: 'system' | 'user' | 'unknown';
    created_at: string;
  };
}

export interface SummaryEvent {
  type: 'summary_update';
  data: {
    id: number;
    content: string;
    created_at: string;
  };
}

export interface SuggestionEvent {
  type: 'suggestion_new';
  data: {
    id: number;
    question: string;
    suggestions: string[];
    created_at: string;
  };
}

export interface TokenUsageEvent {
  type: 'token_usage';
  data: {
    current_tokens: number;
    max_tokens: number;
    percentage: number;
  };
}

export interface MeetingStatusEvent {
  type: 'meeting_status';
  data: {
    status: 'paused' | 'recording';
    meeting_id: string;
  };
}

export interface ErrorEvent {
  type: 'error';
  data: {
    code: string;
    message: string;
    recoverable: boolean;
  };
}

export type WebSocketEvent =
  | TranscriptEvent
  | SummaryEvent
  | SuggestionEvent
  | TokenUsageEvent
  | MeetingStatusEvent
  | ErrorEvent;

export type WebSocketEventHandler = (event: WebSocketEvent) => void;

class WebSocketManager {
  private ws: WebSocket | null = null;
  private meetingId: string | null = null;
  private handlers: Set<WebSocketEventHandler> = new Set();
  private status: WebSocketStatus = 'disconnected';
  private statusHandlers: Set<(status: WebSocketStatus) => void> = new Set();
  private reconnectAttempts = 0;
  private maxReconnectAttempts = 5;
  private reconnectTimeout: ReturnType<typeof setTimeout> | null = null;

  /**
   * Connect to a meeting's WebSocket
   */
  connect(meetingId: string): void {
    if (this.ws && this.meetingId === meetingId) {
      console.log('[WS] Already connected to meeting:', meetingId);
      return;
    }

    // Disconnect from previous meeting
    this.disconnect();

    this.meetingId = meetingId;
    this.reconnectAttempts = 0;
    this.doConnect();
  }

  private doConnect(): void {
    if (!this.meetingId) return;

    this.setStatus('connecting');
    console.log('[WS] Connecting to meeting:', this.meetingId);

    const url = `${WS_BASE}/ws/meeting/${this.meetingId}`;
    this.ws = new WebSocket(url);

    this.ws.onopen = () => {
      console.log('[WS] Connected');
      this.setStatus('connected');
      this.reconnectAttempts = 0;
    };

    this.ws.onmessage = (event) => {
      try {
        const data = JSON.parse(event.data) as WebSocketEvent;
        console.log('[WS] Event:', data.type, data.data);
        this.handlers.forEach((handler) => handler(data));
      } catch (err) {
        console.error('[WS] Failed to parse message:', err);
      }
    };

    this.ws.onerror = (error) => {
      console.error('[WS] Error:', error);
      this.setStatus('error');
    };

    this.ws.onclose = (event) => {
      console.log('[WS] Closed:', event.code, event.reason);
      this.ws = null;

      // Attempt reconnection if not intentionally closed
      if (this.meetingId && this.reconnectAttempts < this.maxReconnectAttempts) {
        this.scheduleReconnect();
      } else {
        this.setStatus('disconnected');
      }
    };
  }

  private scheduleReconnect(): void {
    this.reconnectAttempts++;
    const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempts), 30000);
    console.log(
      `[WS] Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts}/${this.maxReconnectAttempts})`
    );

    this.reconnectTimeout = setTimeout(() => {
      this.doConnect();
    }, delay);
  }

  /**
   * Disconnect from the current meeting
   */
  disconnect(): void {
    if (this.reconnectTimeout) {
      clearTimeout(this.reconnectTimeout);
      this.reconnectTimeout = null;
    }

    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }

    this.meetingId = null;
    this.setStatus('disconnected');
    console.log('[WS] Disconnected');
  }

  /**
   * Get current connection status
   */
  getStatus(): WebSocketStatus {
    return this.status;
  }

  /**
   * Get connected meeting ID
   */
  getMeetingId(): string | null {
    return this.meetingId;
  }

  private setStatus(status: WebSocketStatus): void {
    this.status = status;
    this.statusHandlers.forEach((handler) => handler(status));
  }

  /**
   * Subscribe to WebSocket events
   */
  subscribe(handler: WebSocketEventHandler): () => void {
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  /**
   * Subscribe to connection status changes
   */
  onStatusChange(handler: (status: WebSocketStatus) => void): () => void {
    this.statusHandlers.add(handler);
    // Call immediately with current status
    handler(this.status);
    return () => this.statusHandlers.delete(handler);
  }

  /**
   * Force reconnection
   */
  reconnect(): void {
    if (this.meetingId) {
      this.disconnect();
      this.connect(this.meetingId);
    }
  }
}

// Singleton instance
export const wsManager = new WebSocketManager();
export default wsManager;
