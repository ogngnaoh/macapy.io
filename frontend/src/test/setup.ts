/**
 * Vitest Test Setup
 *
 * This file runs before each test file.
 * Configure global test utilities and mocks here.
 */

import '@testing-library/jest-dom';

// Mock Electron API for tests
Object.defineProperty(window, 'electronAPI', {
  value: {
    getVersion: () => Promise.resolve('0.1.0'),
    getPlatform: () => Promise.resolve('win32' as NodeJS.Platform),
    minimize: () => Promise.resolve(),
    maximize: () => Promise.resolve(),
    close: () => Promise.resolve(),
    isMaximized: () => Promise.resolve(false),
    onMaximizeChange: (_callback: (isMaximized: boolean) => void) => {},
  },
  writable: true,
});

// Mock ResizeObserver (not available in jsdom)
global.ResizeObserver = class ResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
};

// Mock matchMedia (not available in jsdom)
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: (query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: () => {},
    removeListener: () => {},
    addEventListener: () => {},
    removeEventListener: () => {},
    dispatchEvent: () => false,
  }),
});
