// Preload script for Electron - CommonJS format
// This script runs in the preload context with access to Node.js APIs
// and exposes safe methods to the renderer process via contextBridge

const { contextBridge, ipcRenderer } = require('electron');

// Expose protected methods to the renderer process
contextBridge.exposeInMainWorld('electronAPI', {
  // App info
  getVersion: () => ipcRenderer.invoke('app:version'),
  getPlatform: () => ipcRenderer.invoke('app:platform'),

  // Window controls
  minimize: () => ipcRenderer.invoke('window:minimize'),
  maximize: () => ipcRenderer.invoke('window:maximize'),
  close: () => ipcRenderer.invoke('window:close'),
  isMaximized: () => ipcRenderer.invoke('window:isMaximized'),

  // Always-on-top
  setAlwaysOnTop: (value) => ipcRenderer.invoke('window:setAlwaysOnTop', value),
  isAlwaysOnTop: () => ipcRenderer.invoke('window:isAlwaysOnTop'),

  // Compact mode
  setCompactMode: (value) => ipcRenderer.invoke('window:setCompactMode', value),
  isCompactMode: () => ipcRenderer.invoke('window:isCompactMode'),

  // Secure storage for API key
  setApiKey: (apiKey) => ipcRenderer.invoke('storage:setApiKey', apiKey),
  getApiKey: () => ipcRenderer.invoke('storage:getApiKey'),
  deleteApiKey: () => ipcRenderer.invoke('storage:deleteApiKey'),
  hasApiKey: () => ipcRenderer.invoke('storage:hasApiKey'),

  // General settings
  getSetting: (key) => ipcRenderer.invoke('settings:get', key),
  setSetting: (key, value) => ipcRenderer.invoke('settings:set', key, value),

  // Window state listeners
  onMaximizeChange: (callback) => {
    const handler = (_event, isMaximized) => {
      callback(isMaximized);
    };
    ipcRenderer.on('window:maximized', handler);
    return () => ipcRenderer.removeListener('window:maximized', handler);
  },

  // Settings change listeners
  onAlwaysOnTopChange: (callback) => {
    const handler = (_event, value) => callback(value);
    ipcRenderer.on('settings:alwaysOnTopChanged', handler);
    return () => ipcRenderer.removeListener('settings:alwaysOnTopChanged', handler);
  },

  onCompactModeChange: (callback) => {
    const handler = (_event, value) => callback(value);
    ipcRenderer.on('settings:compactModeChanged', handler);
    return () => ipcRenderer.removeListener('settings:compactModeChanged', handler);
  },

  // Global shortcut listeners
  onStartMeeting: (callback) => {
    const handler = () => callback();
    ipcRenderer.on('shortcut:startMeeting', handler);
    return () => ipcRenderer.removeListener('shortcut:startMeeting', handler);
  },

  onEndMeeting: (callback) => {
    const handler = () => callback();
    ipcRenderer.on('shortcut:endMeeting', handler);
    return () => ipcRenderer.removeListener('shortcut:endMeeting', handler);
  },

  onTogglePause: (callback) => {
    const handler = () => callback();
    ipcRenderer.on('shortcut:togglePause', handler);
    return () => ipcRenderer.removeListener('shortcut:togglePause', handler);
  },
});
