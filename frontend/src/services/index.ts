/**
 * Services Index
 * Export all service modules for easy importing
 */

// API Client
export {
  api,
  meetingsApi,
  transcriptsApi,
  aiApi,
  documentsApi,
  audioApi,
  ApiError,
} from './api';

export type {
  Meeting,
  MeetingCreate,
  MeetingUpdate,
  Transcript,
  Summary,
  Suggestion,
  Document,
  AudioDevice,
  AudioStatus,
} from './api';

// WebSocket Manager
export {
  wsManager,
} from './websocket';

export type {
  WebSocketStatus,
  WebSocketEvent,
  TranscriptEvent,
  SummaryEvent,
  SuggestionEvent,
  TokenUsageEvent,
  MeetingStatusEvent,
  ErrorEvent,
  WebSocketEventHandler,
} from './websocket';
