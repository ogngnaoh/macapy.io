---
name: terminal-ui
description: Build terminal-inspired React + TypeScript interfaces for macapy.io meeting assistant. Use when creating components, pages, or features with dark mode, light blue text, monospace typography, and modern CLI aesthetics (VS Code/iTerm2 style).
---

This skill guides creation of terminal-inspired interfaces for the macapy.io meeting assistant using React + TypeScript.

## Design System

CSS variables for consistent theming:

```css
:root {
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

  /* Borders */
  --border-default: #30363d;
  --border-focus: #58a6ff;
}
```

## Typography

Monospace-first approach:

```css
--font-mono: 'JetBrains Mono', 'Fira Code', 'SF Mono', 'Consolas', monospace;
--font-size-sm: 0.8125rem;   /* 13px - timestamps, metadata */
--font-size-base: 0.875rem;  /* 14px - body text */
--font-size-lg: 1rem;        /* 16px - headings */
--line-height: 1.6;
```

Use weight and color for hierarchy, not font variety.

## Component Patterns

**Prompt-style inputs**:
```tsx
<div className="input-group">
  <span className="prompt">&gt;</span>
  <input type="text" placeholder="Type a message..." />
</div>
```

**Transcript output**: Scrollable panel with timestamps, speaker labels in muted color, content in primary blue.

**Status indicators**: Use terminal conventions (`[LIVE]`, `[DONE]`, `[ERR]`) with appropriate accent colors.

**Cards**: Subtle borders (`var(--border-default)`), no shadows. Background uses `--bg-secondary`.

## Motion

Minimal and purposeful:
- **Streaming text**: Character-by-character reveal for AI responses
- **Transitions**: `150ms ease` for state changes
- **No flashy effects**: Professional, clean aesthetic

## Layout

CLI-inspired structure:
- Dense information display
- Sidebar (navigation/controls) + main panel (content)
- Consistent spacing using 4px/8px grid
- Full-height panels with internal scroll
