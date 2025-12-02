import { defineConfig, Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import electron from 'vite-plugin-electron';
import renderer from 'vite-plugin-electron-renderer';
import { resolve } from 'path';
import { copyFileSync, mkdirSync, existsSync } from 'fs';

// Custom plugin to copy preload script without transformation
function copyPreloadPlugin(): Plugin {
  return {
    name: 'copy-preload',
    buildStart() {
      const srcPath = resolve(__dirname, 'electron/preload/index.cjs');
      const destDir = resolve(__dirname, 'dist-electron/preload');
      const destPath = resolve(destDir, 'index.cjs');

      // Ensure destination directory exists
      if (!existsSync(destDir)) {
        mkdirSync(destDir, { recursive: true });
      }

      // Copy the preload script as-is (no transformation)
      copyFileSync(srcPath, destPath);
      console.log('[copy-preload] Copied preload script to dist-electron/preload/index.cjs');
    },
    // Also copy on hot reload during dev
    configureServer(server) {
      server.watcher.on('change', (file) => {
        if (file.endsWith('electron/preload/index.cjs')) {
          const srcPath = resolve(__dirname, 'electron/preload/index.cjs');
          const destPath = resolve(__dirname, 'dist-electron/preload/index.cjs');
          copyFileSync(srcPath, destPath);
          console.log('[copy-preload] Preload script updated');
        }
      });
    }
  };
}

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [
    react(),
    // Copy preload script first (before electron plugin starts)
    copyPreloadPlugin(),
    electron([
      {
        // Main process entry point
        entry: 'electron/main/index.ts',
        onstart(options) {
          options.startup();
        },
        vite: {
          build: {
            outDir: 'dist-electron/main',
            rollupOptions: {
              external: ['electron'],
            },
          },
        },
      },
      // Preload is now handled by copyPreloadPlugin - no vite transformation
    ]),
    renderer(),
  ],
  base: './',
  resolve: {
    alias: {
      '@': resolve(__dirname, './src'),
    },
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
      },
    },
  },
  server: {
    port: 5173,
    strictPort: true,
  },
  clearScreen: false,
});
