/**
 * Platform detection utilities for cross-platform compatibility.
 */

export type Platform = 'darwin' | 'win32' | 'linux';

/**
 * Detects the current platform based on navigator.platform.
 * Returns null if unable to determine or in SSR context.
 */
export function getPlatform(): Platform | null {
  if (typeof navigator === 'undefined') return null;

  const ua = navigator.platform.toLowerCase();
  if (ua.includes('mac')) return 'darwin';
  if (ua.includes('win')) return 'win32';
  if (ua.includes('linux')) return 'linux';

  return null;
}

/**
 * Returns true if running on macOS.
 */
export function isMacOS(): boolean {
  return getPlatform() === 'darwin';
}

/**
 * Returns true if running on Windows.
 */
export function isWindows(): boolean {
  return getPlatform() === 'win32';
}

/**
 * Returns true if running on Linux.
 */
export function isLinux(): boolean {
  return getPlatform() === 'linux';
}

/**
 * Returns the appropriate modifier key symbol for the current platform.
 * ⌘ for macOS, Ctrl for Windows/Linux.
 */
export function getModifierKey(): string {
  return isMacOS() ? '⌘' : 'Ctrl';
}

/**
 * Returns the appropriate modifier key name for the current platform.
 * 'meta' for macOS (Cmd key), 'ctrl' for Windows/Linux.
 */
export function getModifierKeyName(): 'meta' | 'ctrl' {
  return isMacOS() ? 'meta' : 'ctrl';
}
