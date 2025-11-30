import { contextBridge, ipcRenderer } from 'electron';

// Expose protected methods to the renderer process
contextBridge.exposeInMainWorld('electronAPI', {
  // App info
  getVersion: (): Promise<string> => ipcRenderer.invoke('app:version'),
  getPlatform: (): Promise<NodeJS.Platform> => ipcRenderer.invoke('app:platform'),

  // Window controls
  minimize: (): Promise<void> => ipcRenderer.invoke('window:minimize'),
  maximize: (): Promise<void> => ipcRenderer.invoke('window:maximize'),
  close: (): Promise<void> => ipcRenderer.invoke('window:close'),
  isMaximized: (): Promise<boolean> => ipcRenderer.invoke('window:isMaximized'),

  // Always-on-top
  setAlwaysOnTop: (value: boolean): Promise<boolean> =>
    ipcRenderer.invoke('window:setAlwaysOnTop', value),
  isAlwaysOnTop: (): Promise<boolean> => ipcRenderer.invoke('window:isAlwaysOnTop'),

  // Compact mode
  setCompactMode: (value: boolean): Promise<boolean> =>
    ipcRenderer.invoke('window:setCompactMode', value),
  isCompactMode: (): Promise<boolean> => ipcRenderer.invoke('window:isCompactMode'),

  // Secure storage for API key
  setApiKey: (apiKey: string): Promise<boolean> =>
    ipcRenderer.invoke('storage:setApiKey', apiKey),
  getApiKey: (): Promise<string | null> => ipcRenderer.invoke('storage:getApiKey'),
  deleteApiKey: (): Promise<boolean> => ipcRenderer.invoke('storage:deleteApiKey'),
  hasApiKey: (): Promise<boolean> => ipcRenderer.invoke('storage:hasApiKey'),

  // General settings
  getSetting: <T>(key: string): Promise<T> => ipcRenderer.invoke('settings:get', key),
  setSetting: (key: string, value: unknown): Promise<boolean> =>
    ipcRenderer.invoke('settings:set', key, value),

  // Window state listeners
  onMaximizeChange: (callback: (isMaximized: boolean) => void): (() => void) => {
    ipcRenderer.send('window:onMaximizeChange');
    const handler = (_event: Electron.IpcRendererEvent, isMaximized: boolean) => {
      callback(isMaximized);
    };
    ipcRenderer.on('window:maximized', handler);
    return () => ipcRenderer.removeListener('window:maximized', handler);
  },

  // Settings change listeners
  onAlwaysOnTopChange: (callback: (value: boolean) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, value: boolean) => callback(value);
    ipcRenderer.on('settings:alwaysOnTopChanged', handler);
    return () => ipcRenderer.removeListener('settings:alwaysOnTopChanged', handler);
  },

  onCompactModeChange: (callback: (value: boolean) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, value: boolean) => callback(value);
    ipcRenderer.on('settings:compactModeChanged', handler);
    return () => ipcRenderer.removeListener('settings:compactModeChanged', handler);
  },

  // Global shortcut listeners
  onStartMeeting: (callback: () => void): (() => void) => {
    const handler = () => callback();
    ipcRenderer.on('shortcut:startMeeting', handler);
    return () => ipcRenderer.removeListener('shortcut:startMeeting', handler);
  },

  onEndMeeting: (callback: () => void): (() => void) => {
    const handler = () => callback();
    ipcRenderer.on('shortcut:endMeeting', handler);
    return () => ipcRenderer.removeListener('shortcut:endMeeting', handler);
  },

  onTogglePause: (callback: () => void): (() => void) => {
    const handler = () => callback();
    ipcRenderer.on('shortcut:togglePause', handler);
    return () => ipcRenderer.removeListener('shortcut:togglePause', handler);
  },
});

// Type definitions for the exposed API
export interface ElectronAPI {
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
    electronAPI: ElectronAPI;
  }
}
