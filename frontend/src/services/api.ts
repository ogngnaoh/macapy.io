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

export const aiApi = {
  getSummaries: (meetingId: string): Promise<Summary[]> =>
    request(`/api/ai/meetings/${meetingId}/summaries`),

  getSuggestions: (meetingId: string): Promise<Suggestion[]> =>
    request(`/api/ai/meetings/${meetingId}/suggestions`),
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
