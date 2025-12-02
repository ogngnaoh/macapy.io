/**
 * API Client for macapy backend
 * Base URL: http://localhost:8000
 */

const API_BASE = 'http://localhost:8000';

// Generic fetch wrapper with error handling
async function request<T>(
  endpoint: string,
  options: RequestInit = {}
): Promise<T> {
  const url = `${API_BASE}${endpoint}`;

  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options.headers,
    },
  });

  if (!response.ok) {
    const errorData = await response.json().catch(() => ({}));
    throw new ApiError(
      response.status,
      errorData.detail || `HTTP error ${response.status}`,
      errorData
    );
  }

  return response.json();
}

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
    public data?: unknown
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

// =============================================================================
// MEETINGS API
// =============================================================================

export interface Meeting {
  id: string;
  title: string | null;
  platform: string | null;
  status: 'PENDING' | 'IN_PROGRESS' | 'COMPLETED';
  start_time: string;
  end_time: string | null;
}

export interface MeetingCreate {
  title?: string;
  platform?: string;
}

export interface MeetingUpdate {
  title?: string;
  status?: 'PENDING' | 'IN_PROGRESS' | 'COMPLETED';
}

export const meetingsApi = {
  create: (data: MeetingCreate = {}): Promise<Meeting> =>
    request('/api/meetings', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  list: (skip = 0, limit = 100): Promise<Meeting[]> =>
    request(`/api/meetings?skip=${skip}&limit=${limit}`),

  get: (id: string): Promise<Meeting> => request(`/api/meetings/${id}`),

  update: (id: string, data: MeetingUpdate): Promise<Meeting> =>
    request(`/api/meetings/${id}`, {
      method: 'PATCH',
      body: JSON.stringify(data),
    }),

  delete: (id: string): Promise<Meeting> =>
    request(`/api/meetings/${id}`, { method: 'DELETE' }),

  // Start meeting (changes status to IN_PROGRESS, triggers audio capture)
  start: (id: string): Promise<Meeting> =>
    request(`/api/meetings/${id}`, {
      method: 'PATCH',
      body: JSON.stringify({ status: 'IN_PROGRESS' }),
    }),

  // End meeting (changes status to COMPLETED, stops audio capture)
  end: (id: string): Promise<Meeting> =>
    request(`/api/meetings/${id}`, {
      method: 'PATCH',
      body: JSON.stringify({ status: 'COMPLETED' }),
    }),

  // Pause audio capture
  pause: (id: string): Promise<{ status: string; meeting_id: string }> =>
    request(`/api/meetings/${id}/pause`, { method: 'POST' }),

  // Resume audio capture
  resume: (id: string): Promise<{ status: string; meeting_id: string }> =>
    request(`/api/meetings/${id}/resume`, { method: 'POST' }),

  // Get capture status
  getStatus: (
    id: string
  ): Promise<{
    status: string;
    meeting_id: string;
    is_active: boolean;
    is_paused?: boolean;
  }> => request(`/api/meetings/${id}/status`),
};

// =============================================================================
// TRANSCRIPTS API
// =============================================================================

export interface Transcript {
  id: string;
  meeting_id: string;
  speaker: 'system' | 'user' | 'unknown';
  text: string;
  timestamp: number;
  created_at: string;
}

export const transcriptsApi = {
  list: (meetingId: string, skip = 0, limit = 100): Promise<Transcript[]> =>
    request(`/api/transcripts?meeting_id=${meetingId}&skip=${skip}&limit=${limit}`),

  get: (id: string): Promise<Transcript> => request(`/api/transcripts/${id}`),
};

// =============================================================================
// AI API (Summaries & Suggestions)
// =============================================================================

export interface Summary {
  id: number;
  meeting_id: string;
  content: string;
  start_time: string | null;
  end_time: string | null;
  created_at: string;
}

export interface Suggestion {
  id: number;
  meeting_id: string;
  question: string;
  suggestions: string[];
  created_at: string;
}

export interface TokenUsage {
  current_tokens: number;
  max_tokens: number;
  percentage: number;
  breakdown: {
    transcripts: number;
    summaries: number;
  };
  warning: boolean;
  danger: boolean;
}

export interface RecapResponse {
  recap: string;
  tokens_used: number;
  transcript_count: number;
  time_range: {
    start: string | null;
    end: string | null;
  } | null;
}

export interface SummaryGenerateResponse {
  message: string;
  summary: Summary | null;
}

export const aiApi = {
  getSummaries: (meetingId: string): Promise<Summary[]> =>
    request(`/api/ai/meetings/${meetingId}/summaries`),

  getSuggestions: (meetingId: string): Promise<Suggestion[]> =>
    request(`/api/ai/meetings/${meetingId}/suggestions`),

  // Get token usage for a meeting
  getTokenUsage: (meetingId: string): Promise<TokenUsage> =>
    request(`/api/ai/meetings/${meetingId}/tokens`),

  // Get 30-second recap
  getRecap: (meetingId: string, durationSeconds: number = 30): Promise<RecapResponse> =>
    request('/api/ai/recap', {
      method: 'POST',
      body: JSON.stringify({
        meeting_id: meetingId,
        duration_seconds: durationSeconds,
      }),
    }),

  // Trigger manual summary generation
  generateSummary: (meetingId: string): Promise<SummaryGenerateResponse> =>
    request(`/api/ai/meetings/${meetingId}/summaries/generate`, {
      method: 'POST',
    }),

  // Stream AI query response
  streamQuery: async function* (
    meetingId: string,
    question: string,
    includeDocuments: boolean = true
  ): AsyncGenerator<string, void, unknown> {
    const response = await fetch(`${API_BASE}/api/ai/query`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        meeting_id: meetingId,
        question,
        include_documents: includeDocuments,
      }),
    });

    if (!response.ok) {
      throw new ApiError(response.status, 'Query failed');
    }

    const reader = response.body?.getReader();
    if (!reader) throw new Error('No response body');

    const decoder = new TextDecoder();
    let buffer = '';

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n');
      buffer = lines.pop() || '';

      for (const line of lines) {
        if (line.startsWith('data: ')) {
          const data = line.slice(6);
          if (data === '[DONE]') return;
          try {
            const parsed = JSON.parse(data);
            if (parsed.content) yield parsed.content;
            if (parsed.error) {
              const errorMessage = typeof parsed.error === 'string'
                ? parsed.error
                : parsed.error.message || 'Query failed';
              throw new Error(errorMessage);
            }
          } catch (e) {
            // Re-throw API errors, skip malformed JSON
            if (e instanceof Error && e.message !== 'Unexpected end of JSON input') {
              throw e;
            }
          }
        }
      }
    }
  },
};

// =============================================================================
// DOCUMENTS API
// =============================================================================

export interface Document {
  id: number;
  meeting_id: string;
  filename: string;
  file_type: string;
  created_at: string;
}

export const documentsApi = {
  upload: async (meetingId: string, file: File): Promise<Document> => {
    const formData = new FormData();
    formData.append('file', file);

    const response = await fetch(
      `${API_BASE}/api/documents/meetings/${meetingId}/documents`,
      {
        method: 'POST',
        body: formData,
      }
    );

    if (!response.ok) {
      const errorData = await response.json().catch(() => ({}));
      throw new ApiError(
        response.status,
        errorData.detail || 'Upload failed',
        errorData
      );
    }

    return response.json();
  },

  list: (meetingId: string): Promise<Document[]> =>
    request(`/api/documents/meetings/${meetingId}/documents`),

  delete: (id: number): Promise<void> =>
    request(`/api/documents/${id}`, { method: 'DELETE' }),
};

// =============================================================================
// AUDIO API
// =============================================================================

export interface AudioDevice {
  index: number;
  name: string;
  channels: number;
  sample_rate: number;
  is_loopback: boolean;
  is_default: boolean;
}

export interface AudioStatus {
  status: string;
  is_capturing: boolean;
  audio_level: number;
  device_name: string | null;
}

export const audioApi = {
  listDevices: (): Promise<AudioDevice[]> => request('/api/audio/devices'),

  getStatus: (): Promise<AudioStatus> => request('/api/audio/status'),

  start: (
    deviceIndex?: number
  ): Promise<{ status: string; device: string }> =>
    request('/api/audio/start', {
      method: 'POST',
      body: JSON.stringify({ device_index: deviceIndex }),
    }),

  stop: (): Promise<{ status: string }> =>
    request('/api/audio/stop', { method: 'POST' }),

  getLevel: (): Promise<{ audio_level: number; is_capturing: boolean }> =>
    request('/api/audio/level'),
};

// Export all APIs
export const api = {
  meetings: meetingsApi,
  transcripts: transcriptsApi,
  ai: aiApi,
  documents: documentsApi,
  audio: audioApi,
};

export default api;
