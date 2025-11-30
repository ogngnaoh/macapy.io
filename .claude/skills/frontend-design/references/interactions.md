# Interactions & Accessibility Reference

## Table of Contents
1. [Transition Timing](#transition-timing)
2. [Micro-interactions](#micro-interactions)
3. [Focus States](#focus-states)
4. [Keyboard Navigation](#keyboard-navigation)
5. [Dark Mode](#dark-mode)
6. [Performance](#performance)

---

## Transition Timing

Apple-standard easing curve:

```typescript
// tailwind.config.ts
theme: {
  transitionTimingFunction: {
    'standard': 'cubic-bezier(0.16, 1, 0.3, 1)',
  },
}
```

**Timing classes**:
```tsx
const TRANSITIONS = {
  fast: 'duration-150 ease-standard',   // Hovers, toggles
  normal: 'duration-250 ease-standard', // Modals, panels
  slow: 'duration-500 ease-standard',   // Page transitions
};
```

---

## Micro-interactions

**Hover with scale feedback**:
```tsx
<button className="transition-all duration-150 ease-standard hover:bg-bg-tertiary active:scale-98">
  Click me
</button>
```

**Ripple effect (optional)**:
```tsx
const [ripples, setRipples] = useState<Ripple[]>([]);

const handleClick = (e: React.MouseEvent) => {
  const rect = e.currentTarget.getBoundingClientRect();
  const ripple = {
    id: Date.now(),
    x: e.clientX - rect.left,
    y: e.clientY - rect.top,
    size: Math.max(rect.width, rect.height),
  };
  setRipples([...ripples, ripple]);
  setTimeout(() => {
    setRipples(prev => prev.filter(r => r.id !== ripple.id));
  }, 600);
};
```

**Streaming text animation**:
```css
@keyframes blink {
  0%, 100% { opacity: 1; }
  50% { opacity: 0; }
}

.animate-blink {
  animation: blink 1s step-end infinite;
}
```

---

## Focus States

Visible focus ring for accessibility:

```tsx
const focusStyles = cn(
  'focus-visible:outline-none',
  'focus-visible:ring-2 focus-visible:ring-accent-primary',
  'focus-visible:ring-offset-2 focus-visible:ring-offset-bg-primary'
);

// Apply to all interactive elements
<button className={focusStyles}>Action</button>
<input className={focusStyles} />
<a href="#" className={focusStyles}>Link</a>
```

---

## Keyboard Navigation

Arrow key navigation hook:

```tsx
export const useKeyboardNavigation = (itemCount: number) => {
  const [focusedIndex, setFocusedIndex] = useState(0);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    switch (e.key) {
      case 'ArrowDown':
      case 'ArrowRight':
        e.preventDefault();
        setFocusedIndex(prev => (prev + 1) % itemCount);
        break;
      case 'ArrowUp':
      case 'ArrowLeft':
        e.preventDefault();
        setFocusedIndex(prev => (prev - 1 + itemCount) % itemCount);
        break;
      case 'Home':
        e.preventDefault();
        setFocusedIndex(0);
        break;
      case 'End':
        e.preventDefault();
        setFocusedIndex(itemCount - 1);
        break;
    }
  };

  return { focusedIndex, handleKeyDown };
};
```

**Global shortcuts hook**:
```tsx
export const useKeyboardShortcuts = (shortcuts: Record<string, () => void>) => {
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      const key = [
        e.metaKey && 'cmd',
        e.ctrlKey && 'ctrl',
        e.shiftKey && 'shift',
        e.key.toLowerCase(),
      ].filter(Boolean).join('+');

      shortcuts[key]?.();
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [shortcuts]);
};
```

---

## Dark Mode

System-aware theme switching:

```tsx
export const ThemeProvider = ({ children }) => {
  const [isDark, setIsDark] = useState(() => {
    if (typeof window !== 'undefined') {
      return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }
    return true; // Default dark for terminal aesthetic
  });

  useEffect(() => {
    document.documentElement.classList.toggle('dark', isDark);
  }, [isDark]);

  return (
    <ThemeContext.Provider value={{ isDark, setIsDark }}>
      {children}
    </ThemeContext.Provider>
  );
};
```

**CSS variables for themes**:
```css
:root {
  --background: 0 0% 5%;      /* Dark */
  --foreground: 0 0% 88%;     /* Light text */
}

/* Light mode override (if needed) */
.light {
  --background: 0 0% 100%;
  --foreground: 0 0% 8%;
}
```

---

## Performance

**CSS containment**:
```tsx
<div className="contain-paint" style={{ contain: 'layout style paint' }}>
  <ExpensiveComponent />
</div>
```

**Lazy loading sections**:
```tsx
const MetricsPanel = lazy(() => import('./panels/MetricsPanel'));

export const Dashboard = () => (
  <Suspense fallback={<Skeleton />}>
    <MetricsPanel />
  </Suspense>
);
```

**Passive scroll listeners**:
```tsx
useEffect(() => {
  const handler = () => { /* ... */ };
  window.addEventListener('scroll', handler, { passive: true });
  return () => window.removeEventListener('scroll', handler);
}, []);
```

---

## Accessibility Checklist

- [ ] Color contrast >= 4.5:1 (WCAG AA)
- [ ] All interactive elements have visible focus states
- [ ] Keyboard navigation works (Tab, Arrow keys)
- [ ] ARIA labels on dynamic content
- [ ] Semantic HTML (nav, main, article, section)
- [ ] Screen reader announcements for live updates
