# Spacing & Layout Reference

## Table of Contents
1. [8px Grid System](#8px-grid-system)
2. [Container Queries](#container-queries)
3. [Responsive Breakpoints](#responsive-breakpoints)
4. [Fluid Typography](#fluid-typography)
5. [Safe Area Padding](#safe-area-padding)

---

## 8px Grid System

Extend Tailwind spacing with design tokens:

```typescript
// tailwind.config.ts
const spacingScale = {
  'xs': '4px',   // 1 unit
  'sm': '8px',   // 2 units
  'md': '12px',  // 3 units
  'lg': '16px',  // 4 units (baseline)
  'xl': '24px',  // 6 units
  '2xl': '32px', // 8 units
  '3xl': '40px', // 10 units
  '4xl': '48px', // 12 units
  '5xl': '64px', // 16 units
};
```

**Application rules**:
- Padding: `lg` (16px)
- Gap between components: `md`-`lg` (12-16px)
- Section margins: `xl`-`2xl` (24-32px)
- Inner element spacing: `sm` (8px)

---

## Container Queries

Use `@container` for intrinsic responsive design:

```tsx
// Wrapper with container query
<div className="@container space-y-xl">
  <MetricsCard />
</div>

// Component responds to container, not viewport
<div className={cn(
  'p-lg rounded-lg border border-border bg-card',
  '@sm:grid @sm:grid-cols-2 @md:grid-cols-4',
  'flex flex-col' // Fallback
)}>
  {children}
</div>
```

**Benefits**: Components adapt to actual space, reusable across contexts.

---

## Responsive Breakpoints

```
sm:  640px  (small phone)
md:  768px  (tablet)
lg:  1024px (desktop minimum)
xl:  1280px (large desktop)
2xl: 1536px (ultra-wide)
```

**Mobile-first approach**: Start with mobile styles, add breakpoint modifiers for larger screens.

---

## Fluid Typography

Use `clamp()` for smooth scaling:

```typescript
// tailwind.config.ts
fontSize: {
  'xs': ['clamp(0.75rem, 1vw, 0.875rem)', { lineHeight: '1.5rem' }],
  'sm': ['clamp(0.875rem, 1.2vw, 1rem)', { lineHeight: '1.5rem' }],
  'base': ['clamp(1rem, 1.4vw, 1.125rem)', { lineHeight: '1.625rem' }],
  'lg': ['clamp(1.125rem, 1.6vw, 1.25rem)', { lineHeight: '1.75rem' }],
  'xl': ['clamp(1.25rem, 1.8vw, 1.5rem)', { lineHeight: '1.875rem' }],
  '2xl': ['clamp(1.5rem, 2vw, 1.875rem)', { lineHeight: '2.25rem' }],
  '3xl': ['clamp(1.875rem, 2.5vw, 2.25rem)', { lineHeight: '2.75rem' }],
}
```

---

## Safe Area Padding

For notch-aware layouts:

```css
:root {
  --safe-area-top: max(env(safe-area-inset-top), 0px);
  --safe-area-right: max(env(safe-area-inset-right), 0px);
  --safe-area-bottom: max(env(safe-area-inset-bottom), 0px);
  --safe-area-left: max(env(safe-area-inset-left), 0px);
}
```

---

## Aspect Ratios

Maintain consistent ratios for media:

```tsx
// 16:9 chart container
<div className="relative w-full aspect-video bg-muted rounded-lg overflow-hidden">
  <Chart className="absolute inset-0" />
</div>

// Square thumbnail
<div className="aspect-square rounded-md overflow-hidden bg-muted">
  <img src={url} className="w-full h-full object-cover" />
</div>
```
