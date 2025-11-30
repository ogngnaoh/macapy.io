import { app, BrowserWindow, ipcMain, shell, safeStorage, Tray, Menu, globalShortcut, nativeImage } from 'electron';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { existsSync } from 'fs';
import Store from 'electron-store';

// Get __dirname in ESM context, with fallback for bundled environments
let __dirname: string;
try {
  __dirname = dirname(fileURLToPath(import.meta.url));
} catch {
  // Fallback for bundled environment where import.meta.url may not be file://
  __dirname = join(app.getAppPath(), 'dist-electron', 'main');
}

// Initialize electron-store for non-sensitive settings
const store = new Store({
  name: 'macapy-settings',
  defaults: {
    windowBounds: { width: 800, height: 700 },
    alwaysOnTop: false,
    compactMode: false,
    encryptedApiKey: '',
    apiKey: '',
  },
});

// Handle creating/removing shortcuts on Windows when installing/uninstalling.
if (process.platform === 'win32') {
  app.setAppUserModelId(app.getName());
}

let mainWindow: BrowserWindow | null = null;
let tray: Tray | null = null;

const isDev = !app.isPackaged;
const preload = join(__dirname, '../preload/index.cjs');
const distPath = join(__dirname, '../../dist');

// Window size presets
const WINDOW_SIZES = {
  full: { width: 800, height: 700, minWidth: 600, minHeight: 500 },
  compact: { width: 400, height: 350, minWidth: 350, minHeight: 300 },
};

async function createWindow(): Promise<void> {
  const savedBounds = store.get('windowBounds') as { width: number; height: number };
  const alwaysOnTop = store.get('alwaysOnTop') as boolean;
  const compactMode = store.get('compactMode') as boolean;

  const size = compactMode ? WINDOW_SIZES.compact : WINDOW_SIZES.full;

  mainWindow = new BrowserWindow({
    width: savedBounds?.width || size.width,
    height: savedBounds?.height || size.height,
    minWidth: size.minWidth,
    minHeight: size.minHeight,
    title: 'macapy',
    icon: join(__dirname, '../../public/icon.png'),
    backgroundColor: '#0d1117',
    frame: false, // Frameless for custom title bar
    alwaysOnTop: false, // Force disabled as per user request
    webPreferences: {
      preload,
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: false, // Need to disable for electron-store
    },
    show: false,
  });

  // Show window when ready to prevent visual flash
  mainWindow.once('ready-to-show', () => {
    mainWindow?.show();
  });

  // Handle external links
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });

  // Load the app
  if (isDev) {
    // Development: load from Vite dev server
    await mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools();
  } else {
    // Production: load from built files
    await mainWindow.loadFile(join(distPath, 'index.html'));
  }

  // Save window bounds on close
  mainWindow.on('close', () => {
    if (mainWindow && !store.get('compactMode')) {
      store.set('windowBounds', mainWindow.getBounds());
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  // Register maximize/unmaximize listeners once during window creation
  mainWindow.on('maximize', () => {
    mainWindow?.webContents.send('window:maximized', true);
  });
  mainWindow.on('unmaximize', () => {
    mainWindow?.webContents.send('window:maximized', false);
  });
}

// System tray setup
function createTray(): void {
  // Use a simple icon path - in production would be proper icon
  const iconPath = join(__dirname, '../../public/icon.png');

  // Skip tray creation if icon doesn't exist
  if (!existsSync(iconPath)) {
    console.warn('Tray icon not found at:', iconPath, '- skipping tray creation');
    return;
  }

  tray = new Tray(iconPath);
  tray.setToolTip('macapy - Meeting Assistant');

  const contextMenu = Menu.buildFromTemplate([
    {
      label: 'Show/Hide',
      click: () => {
        if (mainWindow?.isVisible()) {
          mainWindow.hide();
        } else {
          mainWindow?.show();
          mainWindow?.focus();
        }
      },
    },
    {
      label: 'Always on Top',
      type: 'checkbox',
      checked: store.get('alwaysOnTop') as boolean,
      click: (menuItem) => {
        store.set('alwaysOnTop', menuItem.checked);
        mainWindow?.setAlwaysOnTop(menuItem.checked);
      },
    },
    { type: 'separator' },
    {
      label: 'Quit',
      click: () => {
        app.quit();
      },
    },
  ]);

  tray.setContextMenu(contextMenu);

  tray.on('click', () => {
    if (mainWindow?.isVisible()) {
      mainWindow.hide();
    } else {
      mainWindow?.show();
      mainWindow?.focus();
    }
  });
}

// Register global shortcuts
function registerShortcuts(): void {
  // Start meeting: Ctrl+Shift+M
  globalShortcut.register('CommandOrControl+Shift+M', () => {
    mainWindow?.webContents.send('shortcut:startMeeting');
    mainWindow?.show();
    mainWindow?.focus();
  });

  // End meeting: Ctrl+Shift+E
  globalShortcut.register('CommandOrControl+Shift+E', () => {
    mainWindow?.webContents.send('shortcut:endMeeting');
  });

  // Pause/Resume: Ctrl+Shift+P
  globalShortcut.register('CommandOrControl+Shift+P', () => {
    mainWindow?.webContents.send('shortcut:togglePause');
  });

  // Toggle compact mode: Ctrl+Shift+C
  globalShortcut.register('CommandOrControl+Shift+C', () => {
    const isCompact = store.get('compactMode') as boolean;
    const newCompact = !isCompact;
    store.set('compactMode', newCompact);

    const size = newCompact ? WINDOW_SIZES.compact : WINDOW_SIZES.full;
    mainWindow?.setMinimumSize(size.minWidth, size.minHeight);
    mainWindow?.setSize(size.width, size.height);
    mainWindow?.webContents.send('settings:compactModeChanged', newCompact);
  });

  // Toggle always on top: Ctrl+Shift+T
  globalShortcut.register('CommandOrControl+Shift+T', () => {
    const isOnTop = mainWindow?.isAlwaysOnTop() ?? false;
    const newOnTop = !isOnTop;
    store.set('alwaysOnTop', newOnTop);
    mainWindow?.setAlwaysOnTop(newOnTop);
    mainWindow?.webContents.send('settings:alwaysOnTopChanged', newOnTop);
  });
}

// App lifecycle
app.whenReady().then(async () => {
  await createWindow();
  createTray();
  registerShortcuts();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});

// IPC Handlers
ipcMain.handle('app:version', () => {
  return app.getVersion();
});

ipcMain.handle('app:platform', () => {
  return process.platform;
});

ipcMain.handle('window:minimize', () => {
  console.log('IPC: window:minimize');
  mainWindow?.minimize();
});

ipcMain.handle('window:maximize', () => {
  console.log('IPC: window:maximize');
  if (mainWindow?.isMaximized()) {
    mainWindow.unmaximize();
  } else {
    mainWindow?.maximize();
  }
});

ipcMain.handle('window:close', () => {
  console.log('IPC: window:close');
  mainWindow?.close();
});

ipcMain.handle('window:isMaximized', () => {
  return mainWindow?.isMaximized() ?? false;
});

// Always-on-top toggle
ipcMain.handle('window:setAlwaysOnTop', (_event, value: boolean) => {
  store.set('alwaysOnTop', value);
  mainWindow?.setAlwaysOnTop(value);
  return value;
});

ipcMain.handle('window:isAlwaysOnTop', () => {
  return mainWindow?.isAlwaysOnTop() ?? false;
});

// Compact mode toggle
ipcMain.handle('window:setCompactMode', (_event, value: boolean) => {
  store.set('compactMode', value);
  const size = value ? WINDOW_SIZES.compact : WINDOW_SIZES.full;
  mainWindow?.setMinimumSize(size.minWidth, size.minHeight);
  mainWindow?.setSize(size.width, size.height);
  return value;
});

ipcMain.handle('window:isCompactMode', () => {
  return store.get('compactMode') as boolean;
});

// Secure storage for API key (using safeStorage)
ipcMain.handle('storage:setApiKey', async (_event, apiKey: string) => {
  if (safeStorage.isEncryptionAvailable()) {
    const encrypted = safeStorage.encryptString(apiKey);
    store.set('encryptedApiKey', encrypted.toString('base64'));
    return true;
  } else {
    // Fallback: store in plain text (not recommended for production)
    store.set('apiKey', apiKey);
    return true;
  }
});

ipcMain.handle('storage:getApiKey', async () => {
  if (safeStorage.isEncryptionAvailable()) {
    const encrypted = store.get('encryptedApiKey') as string | undefined;
    if (encrypted) {
      try {
        const buffer = Buffer.from(encrypted, 'base64');
        return safeStorage.decryptString(buffer);
      } catch {
        return null;
      }
    }
    return null;
  } else {
    return store.get('apiKey') as string | null;
  }
});

ipcMain.handle('storage:deleteApiKey', async () => {
  store.delete('encryptedApiKey');
  store.delete('apiKey');
  return true;
});

ipcMain.handle('storage:hasApiKey', async () => {
  return !!(store.get('encryptedApiKey') || store.get('apiKey'));
});

// General settings storage
ipcMain.handle('settings:get', (_event, key: string) => {
  return store.get(key);
});

ipcMain.handle('settings:set', (_event, key: string, value: unknown) => {
  store.set(key, value);
  return true;
});

// Cleanup on quit
app.on('will-quit', () => {
  globalShortcut.unregisterAll();
});
