/**
 * Zustand Store for macapy
 * Centralized state management for the application
 */

import { create } from 'zustand';
import { devtools, subscribeWithSelector } from 'zustand/middleware';
import type { Meeting, Transcript, Summary, Suggestion, AudioDevice, Document } from '@/services/api';

// =============================================================================
// TYPES
// =============================================================================

export type MeetingStatus = 'idle' | 'starting' | 'recording' | 'paused' | 'ending' | 'error';
export type ViewType = 'meeting' | 'history';

export interface TranscriptSegment {
  id: string;
  text: string;
  timestamp: number;
  speaker: 'system' | 'user' | 'unknown';
  created_at: string;
}

export interface SuggestionData {
  id: number;
  question: string;
  suggestions: string[];
  created_at: string;
}

export interface QueryExchange {
  id: string;
  question: string;
  answer: string;
  timestamp: string;
}

// =============================================================================
// STORE STATE
// =============================================================================

interface AppState {
  // Meeting State
  meeting: {
    current: Meeting | null;
    status: MeetingStatus;
    duration: number;
    error: string | null;
  };

  // Transcript State (TWO columns - system vs user)
  transcript: {
    systemSegments: TranscriptSegment[]; // What others say (loopback audio)
    userSegments: TranscriptSegment[];   // What you say (mic audio)
    isAutoScroll: boolean;
  };

  // Summary State
  summary: {
    items: Summary[];
    isLoading: boolean;
    lastGeneratedAt: Date | null;
  };

  // Query State (user questions to AI)
  query: {
    input: string;
    exchanges: QueryExchange[];
    isLoading: boolean;
  };

  // Suggestion State (auto-generated)
  suggestion: {
    queue: SuggestionData[];
    active: SuggestionData | null;
  };

  // Token Usage State
  tokens: {
    current: number;
    max: number;
    warning: boolean;
  };

  // UI State
  ui: {
    activeView: ViewType;
    isAlwaysOnTop: boolean;
    isCompactMode: boolean;
    isSidebarCollapsed: boolean;
  };

  // History State
  history: {
    meetings: Meeting[];
    selected: Meeting | null;
    searchQuery: string;
    isLoading: boolean;
  };

  // Audio State
  audio: {
    devices: AudioDevice[];
    selectedSystemDevice: number | null;
    selectedMicDevice: number | null;
    audioLevel: number;
    isCapturing: boolean;
  };

  // Documents State
  documents: {
    items: Document[];
    isUploading: boolean;
  };

  // Settings State
  settings: {
    summaryInterval: number;
    apiKeyConfigured: boolean;
  };

  // WebSocket State
  websocket: {
    status: 'disconnected' | 'connecting' | 'connected' | 'error';
  };
}

// =============================================================================
// STORE ACTIONS
// =============================================================================

interface AppActions {
  // Meeting Actions
  setCurrentMeeting: (meeting: Meeting | null) => void;
  setMeetingStatus: (status: MeetingStatus) => void;
  setMeetingDuration: (duration: number) => void;
  incrementDuration: () => void;
  setMeetingError: (error: string | null) => void;
  resetMeeting: () => void;

  // Transcript Actions
  addTranscript: (segment: TranscriptSegment) => void;
  clearTranscripts: () => void;
  setAutoScroll: (enabled: boolean) => void;

  // Summary Actions
  addSummary: (summary: Summary) => void;
  setSummaries: (summaries: Summary[]) => void;
  setSummaryLoading: (loading: boolean) => void;

  // Query Actions
  setQueryInput: (input: string) => void;
  addQueryExchange: (exchange: QueryExchange) => void;
  setQueryLoading: (loading: boolean) => void;
  clearQueryExchanges: () => void;

  // Suggestion Actions
  addSuggestion: (suggestion: SuggestionData) => void;
  dismissActiveSuggestion: () => void;
  clearSuggestions: () => void;

  // Token Actions
  setTokenUsage: (current: number, max: number) => void;

  // UI Actions
  setActiveView: (view: ViewType) => void;
  setAlwaysOnTop: (value: boolean) => void;
  setCompactMode: (value: boolean) => void;
  toggleSidebar: () => void;

  // History Actions
  setHistoryMeetings: (meetings: Meeting[]) => void;
  setSelectedHistoryMeeting: (meeting: Meeting | null) => void;
  setHistorySearchQuery: (query: string) => void;
  setHistoryLoading: (loading: boolean) => void;

  // Audio Actions
  setAudioDevices: (devices: AudioDevice[]) => void;
  setSelectedSystemDevice: (index: number | null) => void;
  setSelectedMicDevice: (index: number | null) => void;
  setAudioLevel: (level: number) => void;
  setIsCapturing: (capturing: boolean) => void;

  // Documents Actions
  setDocuments: (docs: Document[]) => void;
  addDocument: (doc: Document) => void;
  removeDocument: (id: number) => void;
  setDocumentsUploading: (uploading: boolean) => void;

  // Settings Actions
  setSummaryInterval: (interval: number) => void;
  setApiKeyConfigured: (configured: boolean) => void;

  // WebSocket Actions
  setWebSocketStatus: (status: AppState['websocket']['status']) => void;
}

// =============================================================================
// INITIAL STATE
// =============================================================================

const initialState: AppState = {
  meeting: {
    current: null,
    status: 'idle',
    duration: 0,
    error: null,
  },
  transcript: {
    systemSegments: [],
    userSegments: [],
    isAutoScroll: true,
  },
  summary: {
    items: [],
    isLoading: false,
    lastGeneratedAt: null,
  },
  query: {
    input: '',
    exchanges: [],
    isLoading: false,
  },
  suggestion: {
    queue: [],
    active: null,
  },
  tokens: {
    current: 0,
    max: 272000, // GPT-5 nano input limit
    warning: false,
  },
  ui: {
    activeView: 'meeting',
    isAlwaysOnTop: true,
    isCompactMode: false,
    isSidebarCollapsed: false,
  },
  history: {
    meetings: [],
    selected: null,
    searchQuery: '',
    isLoading: false,
  },
  audio: {
    devices: [],
    selectedSystemDevice: null,
    selectedMicDevice: null,
    audioLevel: 0,
    isCapturing: false,
  },
  documents: {
    items: [],
    isUploading: false,
  },
  settings: {
    summaryInterval: 30, // User preference
    apiKeyConfigured: false,
  },
  websocket: {
    status: 'disconnected',
  },
};

// =============================================================================
// CREATE STORE
// =============================================================================

export const useStore = create<AppState & AppActions>()(
  devtools(
    subscribeWithSelector((set) => ({
      ...initialState,

      // Meeting Actions
      setCurrentMeeting: (meeting) =>
        set((state) => ({ meeting: { ...state.meeting, current: meeting } })),

      setMeetingStatus: (status) =>
        set((state) => ({ meeting: { ...state.meeting, status } })),

      setMeetingDuration: (duration) =>
        set((state) => ({ meeting: { ...state.meeting, duration } })),

      incrementDuration: () =>
        set((state) => ({
          meeting: { ...state.meeting, duration: state.meeting.duration + 1 },
        })),

      setMeetingError: (error) =>
        set((state) => ({ meeting: { ...state.meeting, error, status: error ? 'error' : state.meeting.status } })),

      resetMeeting: () =>
        set({
          meeting: initialState.meeting,
          transcript: initialState.transcript,
          summary: initialState.summary,
          query: initialState.query,
          suggestion: initialState.suggestion,
          tokens: initialState.tokens,
        }),

      // Transcript Actions
      addTranscript: (segment) =>
        set((state) => {
          const isSystem = segment.speaker === 'system';
          return {
            transcript: {
              ...state.transcript,
              systemSegments: isSystem
                ? [...state.transcript.systemSegments, segment]
                : state.transcript.systemSegments,
              userSegments: !isSystem
                ? [...state.transcript.userSegments, segment]
                : state.transcript.userSegments,
            },
          };
        }),

      clearTranscripts: () =>
        set((state) => ({
          transcript: { ...state.transcript, systemSegments: [], userSegments: [] },
        })),

      setAutoScroll: (enabled) =>
        set((state) => ({
          transcript: { ...state.transcript, isAutoScroll: enabled },
        })),

      // Summary Actions
      addSummary: (summary) =>
        set((state) => ({
          summary: {
            ...state.summary,
            items: [...state.summary.items, summary],
            lastGeneratedAt: new Date(),
          },
        })),

      setSummaries: (summaries) =>
        set((state) => ({ summary: { ...state.summary, items: summaries } })),

      setSummaryLoading: (loading) =>
        set((state) => ({ summary: { ...state.summary, isLoading: loading } })),

      // Query Actions
      setQueryInput: (input) =>
        set((state) => ({ query: { ...state.query, input } })),

      addQueryExchange: (exchange) =>
        set((state) => ({
          query: { ...state.query, exchanges: [...state.query.exchanges, exchange] },
        })),

      setQueryLoading: (loading) =>
        set((state) => ({ query: { ...state.query, isLoading: loading } })),

      clearQueryExchanges: () =>
        set((state) => ({ query: { ...state.query, exchanges: [] } })),

      // Suggestion Actions
      addSuggestion: (suggestion) =>
        set((state) => {
          const newQueue = [...state.suggestion.queue, suggestion];
          return {
            suggestion: {
              queue: newQueue,
              active: state.suggestion.active || suggestion,
            },
          };
        }),

      dismissActiveSuggestion: () =>
        set((state) => {
          const [, ...rest] = state.suggestion.queue;
          return {
            suggestion: {
              queue: rest,
              active: rest[0] || null,
            },
          };
        }),

      clearSuggestions: () =>
        set({ suggestion: { queue: [], active: null } }),

      // Token Actions
      setTokenUsage: (current, max) =>
        set({
          tokens: {
            current,
            max,
            warning: current / max > 0.8,
          },
        }),

      // UI Actions
      setActiveView: (view) =>
        set((state) => ({ ui: { ...state.ui, activeView: view } })),

      setAlwaysOnTop: (value) =>
        set((state) => ({ ui: { ...state.ui, isAlwaysOnTop: value } })),

      setCompactMode: (value) =>
        set((state) => ({ ui: { ...state.ui, isCompactMode: value } })),

      toggleSidebar: () =>
        set((state) => ({
          ui: { ...state.ui, isSidebarCollapsed: !state.ui.isSidebarCollapsed },
        })),

      // History Actions
      setHistoryMeetings: (meetings) =>
        set((state) => ({ history: { ...state.history, meetings } })),

      setSelectedHistoryMeeting: (meeting) =>
        set((state) => ({ history: { ...state.history, selected: meeting } })),

      setHistorySearchQuery: (query) =>
        set((state) => ({ history: { ...state.history, searchQuery: query } })),

      setHistoryLoading: (loading) =>
        set((state) => ({ history: { ...state.history, isLoading: loading } })),

      // Audio Actions
      setAudioDevices: (devices) =>
        set((state) => ({ audio: { ...state.audio, devices } })),

      setSelectedSystemDevice: (index) =>
        set((state) => ({ audio: { ...state.audio, selectedSystemDevice: index } })),

      setSelectedMicDevice: (index) =>
        set((state) => ({ audio: { ...state.audio, selectedMicDevice: index } })),

      setAudioLevel: (level) =>
        set((state) => ({ audio: { ...state.audio, audioLevel: level } })),

      setIsCapturing: (capturing) =>
        set((state) => ({ audio: { ...state.audio, isCapturing: capturing } })),

      // Documents Actions
      setDocuments: (docs) =>
        set((state) => ({ documents: { ...state.documents, items: docs } })),

      addDocument: (doc) =>
        set((state) => ({
          documents: { ...state.documents, items: [...state.documents.items, doc] },
        })),

      removeDocument: (id) =>
        set((state) => ({
          documents: {
            ...state.documents,
            items: state.documents.items.filter((d) => d.id !== id),
          },
        })),

      setDocumentsUploading: (uploading) =>
        set((state) => ({ documents: { ...state.documents, isUploading: uploading } })),

      // Settings Actions
      setSummaryInterval: (interval) =>
        set((state) => ({ settings: { ...state.settings, summaryInterval: interval } })),

      setApiKeyConfigured: (configured) =>
        set((state) => ({ settings: { ...state.settings, apiKeyConfigured: configured } })),

      // WebSocket Actions
      setWebSocketStatus: (status) => set({ websocket: { status } }),
    })),
    { name: 'macapy-store' }
  )
);

// =============================================================================
// SELECTORS (for optimized re-renders)
// =============================================================================

export const selectMeeting = (state: AppState) => state.meeting;
export const selectTranscript = (state: AppState) => state.transcript;
export const selectSummary = (state: AppState) => state.summary;
export const selectSuggestion = (state: AppState) => state.suggestion;
export const selectTokens = (state: AppState) => state.tokens;
export const selectUI = (state: AppState) => state.ui;
export const selectHistory = (state: AppState) => state.history;
export const selectAudio = (state: AppState) => state.audio;
export const selectDocuments = (state: AppState) => state.documents;
export const selectSettings = (state: AppState) => state.settings;
export const selectWebSocket = (state: AppState) => state.websocket;

export default useStore;
