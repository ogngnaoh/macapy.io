/**
 * TypeScript Type Definitions
 *
 * Shared types and interfaces used throughout the application.
 * These should mirror the backend Pydantic schemas.
 */

// Meeting Types
export interface Meeting {
  id: string;
  title: string;
  status: MeetingStatus;
  started_at: string | null;
  ended_at: string | null;
  created_at: string;
  updated_at: string;
}

export type MeetingStatus = 'PENDING' | 'IN_PROGRESS' | 'COMPLETED' | 'CANCELLED';

export interface MeetingCreate {
  title: string;
}

export interface MeetingUpdate {
  title?: string;
  status?: MeetingStatus;
}

// Transcript Types
export interface Transcript {
  id: string;
  meeting_id: string;
  content: string;
  timestamp: string;
  speaker: string | null;
  confidence: number | null;
  created_at: string;
}

export interface TranscriptCreate {
  meeting_id: string;
  content: string;
  timestamp: string;
  speaker?: string;
  confidence?: number;
}

// Document Types
export interface ContextDocument {
  id: string;
  meeting_id: string | null;
  filename: string;
  file_type: string;
  file_size: number;
  status: DocumentStatus;
  created_at: string;
}

export type DocumentStatus = 'PENDING' | 'PROCESSING' | 'READY' | 'ERROR';

// Suggestion Types
export interface Suggestion {
  id: string;
  meeting_id: string;
  content: string;
  context: string | null;
  relevance_score: number | null;
  created_at: string;
}

// Summary Types
export interface Summary {
  id: string;
  meeting_id: string;
  content: string;
  summary_type: SummaryType;
  created_at: string;
}

export type SummaryType = 'ROLLING' | 'FINAL';

// Audio Types
export interface AudioDevice {
  id: string;
  name: string;
  is_default: boolean;
  sample_rate: number;
  channels: number;
}

export interface AudioCaptureStatus {
  is_capturing: boolean;
  device_id: string | null;
  duration_seconds: number;
}

// WebSocket Event Types
export interface WSMessage<T = unknown> {
  type: WSEventType;
  data: T;
  timestamp: string;
}

export type WSEventType =
  | 'transcript'
  | 'suggestion'
  | 'summary'
  | 'meeting_status'
  | 'audio_level'
  | 'error';

export interface WSTranscriptEvent {
  transcript: Transcript;
}

export interface WSSuggestionEvent {
  suggestion: Suggestion;
}

export interface WSSummaryEvent {
  summary: Summary;
}

export interface WSMeetingStatusEvent {
  meeting_id: string;
  status: MeetingStatus;
}

export interface WSAudioLevelEvent {
  level: number; // 0.0 to 1.0
  is_speech: boolean;
}

export interface WSErrorEvent {
  code: string;
  message: string;
}

// API Response Types
export interface APIResponse<T> {
  data: T;
  message?: string;
}

export interface APIError {
  detail: string;
  code?: string;
}

export interface PaginatedResponse<T> {
  items: T[];
  total: number;
  page: number;
  page_size: number;
  has_more: boolean;
}

// UI State Types
export type AppPage = 'meeting' | 'history' | 'documents' | 'settings';

export interface ToastNotification {
  id: string;
  type: 'success' | 'error' | 'warning' | 'info';
  title: string;
  message?: string;
  duration?: number;
}
