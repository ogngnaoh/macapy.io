---
name: frontend-design
description: Build macOS-inspired React + TypeScript dashboards with Apple HIG principles for macapy.io. Use when creating UI components, layouts, pages, or features requiring dark terminal aesthetics with modern UX patterns (backdrop blur, fluid typography, 8px grid, micro-interactions). Triggers on component creation, layout design, styling, responsive design, accessibility improvements, or any frontend visual implementation.
---

# Frontend Design for macapy.io

Build terminal-inspired interfaces following Apple's Human Interface Guidelines adapted for web with TypeScript, Tailwind CSS, and shadcn/ui.

## Core Design Principles

| Principle | Implementation |
|-----------|----------------|
| **Clarity** | Clear visual hierarchy, logical grouping, eliminate redundancy |
| **Deference** | Subtle backgrounds, transparent/frosted components, motion restraint |
| **Depth** | Layering via shadows, z-index strategy, backdrop blur |
| **Consistency** | Reusable components, uniform spacing, standardized interactions |
| **Feedback** | Micro-interactions, loading states, visual confirmation |

## Design Tokens

```css
:root {
  /* Backgrounds */
  --bg-primary: #0d0d0d;
  --bg-secondary: #161616;
  --bg-tertiary: #1a1a1a;

  /* Text */
  --text-primary: #e0e0e0;
  --text-secondary: #b0b0b0;
  --text-muted: #8b949e;
  --text-dim: #484f58;

  /* Accent */
  --accent-primary: #00d4ff;
  --accent-success: #3fb950;
  --accent-warning: #d29922;
  --accent-error: #f85149;

  /* Borders */
  --border-default: #30363d;
  --border-focus: #00d4ff;

  /* Spacing (8px base) */
  --space-xs: 4px;
  --space-sm: 8px;
  --space-md: 12px;
  --space-lg: 16px;
  --space-xl: 24px;
  --space-2xl: 32px;

  /* Typography */
  --font-mono: 'JetBrains Mono', 'Fira Code', monospace;
}
```

## Spacing System

Use 8px base grid. Apply spacing scale consistently:

| Token | Value | Usage |
|-------|-------|-------|
| `xs` | 4px | Inner element gaps |
| `sm` | 8px | Inline spacing, tight gaps |
| `md` | 12px | Component internal padding |
| `lg` | 16px | Standard padding, gaps |
| `xl` | 24px | Section spacing |
| `2xl` | 32px | Major section margins |

## Layout Patterns

**Grid structure**: Use CSS Grid for page layout, Flexbox for components.

```tsx
// Dashboard layout
<div className="grid grid-cols-12 gap-lg min-h-screen">
  <aside className="col-span-2 border-r border-border-default" />
  <main className="col-span-10 p-lg">{children}</main>
</div>
```

**Sticky headers with blur**:
```tsx
<header className="sticky top-0 z-30 bg-bg-primary/80 backdrop-blur-md border-b border-border-default/40">
```

## Component Standards

**Buttons**: Use `duration-150 ease-standard` transitions, `active:scale-98` for press feedback.

**Cards**: Subtle borders, no shadows unless hovering. Background `bg-secondary`.

**Inputs**: Terminal-style with prompt prefix (`>`), monospace font.

**Status badges**: Terminal conventions `[LIVE]`, `[DONE]`, `[ERR]` with accent colors.

## Transitions

Use Apple-standard easing: `cubic-bezier(0.16, 1, 0.3, 1)`

| Speed | Duration | Usage |
|-------|----------|-------|
| Fast | 150ms | Hovers, active states |
| Normal | 250ms | Page transitions, modals |
| Slow | 500ms | Complex animations |

```tsx
// Tailwind config
transitionTimingFunction: {
  'standard': 'cubic-bezier(0.16, 1, 0.3, 1)',
}
```

## References

- **Spacing & Layout details**: See [references/spacing-layout.md](references/spacing-layout.md)
- **Component patterns**: See [references/components.md](references/components.md)
- **Interactions & accessibility**: See [references/interactions.md](references/interactions.md)
