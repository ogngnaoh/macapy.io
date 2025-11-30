# Component Patterns Reference

## Table of Contents
1. [Button Variants](#button-variants)
2. [Cards](#cards)
3. [Inputs](#inputs)
4. [Sticky Headers](#sticky-headers)
5. [Status Indicators](#status-indicators)
6. [Panels & Layouts](#panels--layouts)

---

## Button Variants

```tsx
const SIZES = {
  sm: 'px-md py-xs text-xs',   // Compact
  md: 'px-lg py-sm text-sm',   // Default
  lg: 'px-xl py-md text-base', // Large
};

export const Button = ({ size = 'md', variant = 'primary', ...props }) => (
  <button
    className={cn(
      'rounded-md font-medium font-mono',
      'transition-all duration-150 ease-standard',
      'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2',
      'active:scale-98',
      SIZES[size],
      variant === 'primary' && 'bg-accent-primary text-bg-primary hover:bg-accent-primary/90',
      variant === 'secondary' && 'bg-bg-tertiary text-text-primary hover:bg-bg-tertiary/80',
      variant === 'ghost' && 'hover:bg-bg-tertiary',
      variant === 'danger' && 'bg-accent-error text-white hover:bg-accent-error/90',
    )}
    {...props}
  />
);
```

---

## Cards

Terminal-style cards with subtle styling:

```tsx
export const Card = ({ children, interactive = false }) => (
  <div
    className={cn(
      'p-lg rounded-lg border border-border-default bg-bg-secondary',
      'transition-all duration-250 ease-standard',
      interactive && [
        'hover:shadow-lg hover:border-accent-primary/50',
        'active:scale-98 cursor-pointer'
      ]
    )}
  >
    {children}
  </div>
);
```

**Rules**:
- No shadows at rest
- Subtle border using `--border-default`
- Background uses `--bg-secondary`
- Hover adds shadow and border highlight

---

## Inputs

Terminal-style with prompt prefix:

```tsx
export const Input = ({ prefix = '>', ...props }) => (
  <div className="flex items-center gap-sm bg-bg-tertiary rounded-md border border-border-default focus-within:border-accent-primary">
    <span className="pl-md text-text-muted font-mono">{prefix}</span>
    <input
      className={cn(
        'flex-1 bg-transparent py-sm pr-md font-mono text-text-primary',
        'placeholder:text-text-dim',
        'focus:outline-none'
      )}
      {...props}
    />
  </div>
);
```

---

## Sticky Headers

Compress on scroll with backdrop blur:

```tsx
export const PageHeader = ({ title, actions }) => {
  const [isCompressed, setIsCompressed] = useState(false);

  useEffect(() => {
    const handleScroll = () => setIsCompressed(window.scrollY > 40);
    window.addEventListener('scroll', handleScroll, { passive: true });
    return () => window.removeEventListener('scroll', handleScroll);
  }, []);

  return (
    <header
      className={cn(
        'sticky top-0 z-30',
        'bg-bg-primary/80 backdrop-blur-md',
        'border-b border-border-default/40',
        'transition-all duration-200',
        isCompressed ? 'py-sm shadow-sm' : 'py-lg'
      )}
    >
      <div className="flex items-center justify-between px-lg">
        <h1 className={cn(
          'font-semibold font-mono transition-all duration-200',
          isCompressed ? 'text-lg' : 'text-2xl'
        )}>
          {title}
        </h1>
        <div className="flex items-center gap-md">{actions}</div>
      </div>
    </header>
  );
};
```

---

## Status Indicators

Terminal-style badges:

```tsx
const STATUS_STYLES = {
  live: 'bg-accent-success/20 text-accent-success',
  done: 'bg-text-muted/20 text-text-muted',
  error: 'bg-accent-error/20 text-accent-error',
  warning: 'bg-accent-warning/20 text-accent-warning',
};

export const StatusBadge = ({ status }) => (
  <span className={cn(
    'px-sm py-xs rounded text-xs font-mono uppercase tracking-wider',
    STATUS_STYLES[status]
  )}>
    [{status}]
  </span>
);
```

---

## Panels & Layouts

Two-column split layout:

```tsx
export const SplitLayout = ({ left, right, ratio = '3/2' }) => {
  const [leftCols, rightCols] = ratio === '3/2' ? [3, 2] : [1, 1];

  return (
    <div className="flex-1 flex min-h-0">
      <div className={`w-${leftCols}/5 flex flex-col min-h-0 border-r border-border-default`}>
        {left}
      </div>
      <div className={`w-${rightCols}/5 flex flex-col min-h-0`}>
        {right}
      </div>
    </div>
  );
};
```

Scrollable panel with auto-scroll:

```tsx
export const ScrollPanel = ({ children, autoScroll = true }) => {
  const ref = useRef<HTMLDivElement>(null);
  const [items, setItems] = useState([]);

  useEffect(() => {
    if (autoScroll && ref.current) {
      ref.current.scrollTop = ref.current.scrollHeight;
    }
  }, [items.length, autoScroll]);

  return (
    <div ref={ref} className="flex-1 overflow-y-auto p-lg custom-scrollbar">
      {children}
    </div>
  );
};
```
