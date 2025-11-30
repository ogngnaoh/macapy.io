import { test, expect, _electron as electron } from '@playwright/test';
import { resolve } from 'path';

test.describe('TitleBar and Window Behavior', () => {
    let electronApp: any;

    test.beforeEach(async () => {
        // Launch Electron app
        // Assuming we run from frontend directory
        const mainScript = resolve(process.cwd(), 'dist-electron/main/index.js');
        console.log('Launching app from:', mainScript);

        electronApp = await electron.launch({
            args: [mainScript],
        });

        // Capture console logs
        const window = await electronApp.firstWindow();
        window.on('console', msg => console.log(`[Renderer Console] ${msg.type()}: ${msg.text()}`));
    });

    test.afterEach(async () => {
        // Close app
        if (electronApp) {
            await electronApp.close();
        }
    });

    test('Window should not be always on top', async () => {
        const window = await electronApp.firstWindow();
        const isAlwaysOnTop = await electronApp.evaluate(async ({ BrowserWindow }) => {
            const win = BrowserWindow.getAllWindows()[0];
            return win.isAlwaysOnTop();
        });
        expect(isAlwaysOnTop).toBe(false);
    });

    test('Minimize button should minimize window', async () => {
        const window = await electronApp.firstWindow();

        // Wait for app to load
        await window.waitForLoadState('domcontentloaded');

        // Click minimize button
        await window.click('[data-testid="window-minimize"]');

        // Check if minimized
        const isMinimized = await electronApp.evaluate(async ({ BrowserWindow }) => {
            const win = BrowserWindow.getAllWindows()[0];
            return win.isMinimized();
        });

        expect(isMinimized).toBe(true);
    });

    test('Maximize button should maximize window', async () => {
        const window = await electronApp.firstWindow();
        await window.waitForLoadState('domcontentloaded');

        // Click maximize button
        await window.click('[data-testid="window-maximize"]');

        // Check if maximized
        const isMaximized = await electronApp.evaluate(async ({ BrowserWindow }) => {
            const win = BrowserWindow.getAllWindows()[0];
            return win.isMaximized();
        });

        expect(isMaximized).toBe(true);
    });

    // Note: Testing close is tricky because it kills the app/window. 
    // We can verify the IPC call or that the window count drops.
    test('Close button should close window', async () => {
        const window = await electronApp.firstWindow();
        await window.waitForLoadState('domcontentloaded');

        // Click close button
        await window.click('[data-testid="window-close"]');

        // Wait a bit for close to happen
        await new Promise(resolve => setTimeout(resolve, 1000));

        // Check window count
        const windowCount = await electronApp.evaluate(async ({ BrowserWindow }) => {
            return BrowserWindow.getAllWindows().length;
        });

        expect(windowCount).toBe(0);
    });
});
