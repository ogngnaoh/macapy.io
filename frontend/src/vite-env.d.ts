/// <reference types="vite/client" />

// Electron API types
interface ElectronAPI {
  // App info
  getVersion: () => Promise<string>;
  getPlatform: () => Promise<NodeJS.Platform>;

  // Window controls
  minimize: () => Promise<void>;
  maximize: () => Promise<void>;
  close: () => Promise<void>;
  isMaximized: () => Promise<boolean>;

  // Always-on-top
  setAlwaysOnTop: (value: boolean) => Promise<boolean>;
  isAlwaysOnTop: () => Promise<boolean>;

  // Compact mode
  setCompactMode: (value: boolean) => Promise<boolean>;
  isCompactMode: () => Promise<boolean>;

  // Secure storage
  setApiKey: (apiKey: string) => Promise<boolean>;
  getApiKey: () => Promise<string | null>;
  deleteApiKey: () => Promise<boolean>;
  hasApiKey: () => Promise<boolean>;

  // General settings
  getSetting: <T>(key: string) => Promise<T>;
  setSetting: (key: string, value: unknown) => Promise<boolean>;

  // Listeners
  onMaximizeChange: (callback: (isMaximized: boolean) => void) => () => void;
  onAlwaysOnTopChange: (callback: (value: boolean) => void) => () => void;
  onCompactModeChange: (callback: (value: boolean) => void) => () => void;
  onStartMeeting: (callback: () => void) => () => void;
  onEndMeeting: (callback: () => void) => () => void;
  onTogglePause: (callback: () => void) => () => void;
}

declare global {
  interface Window {
    electronAPI?: ElectronAPI;
  }
}

export { };
