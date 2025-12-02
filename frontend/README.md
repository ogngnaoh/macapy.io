# macapy Frontend

Electron + React + TypeScript desktop application for the macapy meeting assistant.

## Quick Start

```bash
# Install dependencies
npm install

# Run in development mode (Electron + Vite with hot reload)
npm run dev

# Run web-only mode (for faster React development)
npm run dev:web
```

## Tech Stack

- **Electron 28+** - Desktop application framework
- **React 18** - UI library
- **TypeScript** - Type-safe JavaScript
- **Vite** - Build tool with hot module replacement
- **TailwindCSS** - Utility-first CSS framework
- **Zustand** - Lightweight state management
- **Radix UI** - Accessible UI primitives

## Project Structure

```
frontend/
|-- electron/
|   |-- main/           # Electron main process
|   |-- preload/        # Preload scripts for IPC
|-- src/
|   |-- components/
|   |   |-- layout/     # App shell components (TitleBar, Sidebar, etc.)
|   |   |-- meeting/    # Active meeting view components
|   |   |-- history/    # Meeting history components
|   |   |-- common/     # Shared UI components
|   |-- hooks/          # Custom React hooks
|   |-- store/          # Zustand state stores
|   |-- services/       # API and WebSocket services
|   |-- types/          # TypeScript type definitions
|   |-- utils/          # Helper functions
|   |-- styles/         # Global styles and CSS variables
|-- build/              # Electron builder resources
```

## Scripts

| Script | Description |
|--------|-------------|
| `npm run dev` | Start Electron app with hot reload |
| `npm run dev:web` | Start React app in browser only |
| `npm run build` | Build for production |
| `npm run build:win` | Build Windows installer |
| `npm run build:mac` | Build macOS app |
| `npm run build:linux` | Build Linux packages |
| `npm run test` | Run tests with Vitest |
| `npm run lint` | Lint with ESLint |
| `npm run typecheck` | TypeScript type checking |

## Design System

The app uses a terminal-inspired dark theme with the following color palette:

```css
/* Backgrounds */
--bg-primary: #0d1117;
--bg-secondary: #161b22;
--bg-tertiary: #21262d;

/* Text */
--text-primary: #58a6ff;    /* Light blue - main text */
--text-secondary: #79c0ff;  /* Lighter blue - emphasis */
--text-muted: #8b949e;      /* Gray - secondary info */
--text-dim: #484f58;        /* Dim - timestamps, hints */

/* Accents */
--accent-success: #3fb950;  /* Green - success states */
--accent-warning: #d29922;  /* Yellow - warnings */
--accent-error: #f85149;    /* Red - errors */
--accent-cyan: #39c5cf;     /* Cyan - highlights */
```

**Typography:** JetBrains Mono (monospace-first)

## Development Notes

- The app uses `vite-plugin-electron` for seamless Electron integration
- Preload scripts expose a type-safe `electronAPI` to the renderer process
- The `dev:web` script is useful for faster iteration on React components
- State management uses Zustand with separate stores per domain
- API services should use the async patterns established in the backend

## Building

```bash
# Install dependencies
npm install

# Build for current platform
npm run build

# Build for Windows specifically
npm run build:win
```

Build outputs are placed in the `release/` directory.
