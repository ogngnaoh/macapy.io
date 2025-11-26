/// <reference types="vite/client" />

// Electron API types
interface ElectronAPI {
  getVersion: () => Promise<string>;
  getPlatform: () => Promise<NodeJS.Platform>;
  minimize: () => Promise<void>;
  maximize: () => Promise<void>;
  close: () => Promise<void>;
  isMaximized: () => Promise<boolean>;
  onMaximizeChange: (callback: (isMaximized: boolean) => void) => void;
}

declare global {
  interface Window {
    electronAPI?: ElectronAPI;
  }
}

export {};
