# Figma to Code Integration Rules - macapy.io

## Project Context

**macapy.io** is an AI-powered personal meeting assistant built as an **Electron desktop application** with React 18 + TypeScript. The application uses a dark, modern UI with purple accents and follows a floating overlay architecture for meeting contexts.

---

## 1. Design Token Definitions

### Color System (HSL Format in CSS Custom Properties)

**Location**: `frontend/src/index.css`

```css
:root {
  /* Slate 950 as background */
  --background: 222 47% 11%;
  --foreground: 210 40% 98%;

  /* Slate 900 as card/secondary background */
  --card: 222 47% 11%;
  --card-foreground: 210 40% 98%;

  /* Purple 600 as primary */
  --primary: 271 81% 56%;
  --primary-foreground: 210 40% 98%;

  --secondary: 217 33% 17%;
  --secondary-foreground: 210 40% 98%;

  --muted: 217 33% 17%;
  --muted-foreground: 215 20% 65%;

  --accent: 217 33% 17%;
  --accent-foreground: 210 40% 98%;

  --destructive: 0 62.8% 30.6%;
  --destructive-foreground: 210 40% 98%;

  /* Slate 700/50 for borders */
  --border: 217 33% 17%;
  --input: 217 33% 17%;
  --ring: 271 81% 56%;

  --radius: 0.75rem; /* rounded-xl */
}
```

### Tailwind Extended Colors

**Location**: `frontend/tailwind.config.js`

```javascript
colors: {
  border: "var(--border)",
  input: "var(--input)",
  ring: "var(--ring)",
  background: "var(--background)",
  foreground: "var(--foreground)",
  primary: {
    600: '#7c3aed', // Purple 600
    700: '#6d28d9',
    800: '#5b21b6',
    900: '#4c1d95',
  },
  'brand-purple': '#7c3aed',
  'brand-dark': '#020617', // Slate 950
}
```

### Mapping Figma Colors to Code

When converting Figma designs:

| Figma Layer Style | CSS Token | Tailwind Class |
|-------------------|-----------|----------------|
| Background/Primary | `--background` | `bg-background` |
| Text/Primary | `--foreground` | `text-foreground` |
| Accent/Purple | `--primary` | `bg-primary` or `bg-brand-purple` |
| Card Background | `--card` | `bg-card` |
| Border/Divider | `--border` | `border-border` |
| Muted Text | `--muted-foreground` | `text-muted-foreground` |

**Example Conversion**:
```tsx
// Figma: Fill = #7c3aed (Purple 600)
<Button className="bg-brand-purple hover:bg-primary-700 text-white">
  Start Meeting
</Button>

// Figma: Fill = #020617 (Slate 950), Border = #334155
<Card className="bg-background border-border rounded-xl">
  {/* Content */}
</Card>
```

---

## 2. Component Library & Architecture

### UI Component System: shadcn/ui + Radix UI

**Location**: `frontend/src/components/ui/`

The project uses **shadcn/ui** components (v0 style) which are:
- Built on **Radix UI primitives** (@radix-ui/react-*)
- Fully customizable and owned by the project (not npm packages)
- Styled with **Tailwind CSS** utility classes
- Type-safe with **TypeScript**

### Component Structure Pattern

All UI components follow this pattern:

```tsx
import * as React from "react";
import { cn } from "./utils"; // Utility for className merging

function ComponentName({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="component-name"
      className={cn(
        "base-utility-classes",
        className
      )}
      {...props}
    />
  );
}

export { ComponentName };
```

### Available shadcn/ui Components

**Location**: `frontend/src/components/ui/`

- `accordion.tsx` - Collapsible sections
- `alert-dialog.tsx` - Modal confirmations
- `avatar.tsx` - User profile images
- `badge.tsx` - Status indicators
- `button.tsx` - Primary interactive elements
- `card.tsx` - Container components
- `carousel.tsx` - Image/content sliders
- `checkbox.tsx` - Form selections
- `dialog.tsx` - Modal dialogs
- `dropdown-menu.tsx` - Contextual menus
- `input.tsx` - Text inputs
- `label.tsx` - Form labels
- `progress.tsx` - Loading indicators
- `scroll-area.tsx` - Custom scrollbars
- `select.tsx` - Dropdown selects
- `separator.tsx` - Visual dividers
- `sheet.tsx` - Slide-in panels
- `sidebar.tsx` - Navigation sidebars
- `skeleton.tsx` - Loading placeholders
- `slider.tsx` - Range inputs
- `switch.tsx` - Toggle switches
- `tabs.tsx` - Tabbed interfaces
- `textarea.tsx` - Multi-line inputs
- `tooltip.tsx` - Hover descriptions

### Custom Application Components

**Location**: `frontend/src/components/`

- `MeetingHeader.tsx` - Meeting title, timer, controls
- `MeetingSummary.tsx` - AI-generated summaries
- `LiveTranscript.tsx` - iMessage-style chat bubbles
- `ResponseSuggestions.tsx` - AI response cards
- `DocumentsSidebar.tsx` - File context panel
- `FloatingAssistant.tsx` - Compact overlay input
- `DuringMeetingDashboard.tsx` - Main meeting view
- `PostMeetingDashboard.tsx` - Startup window
- `CapybaraLogo.tsx` - Brand SVG component

### Component Usage Example (Button)

**File**: `frontend/src/components/ui/button.tsx`

```tsx
import { cva, type VariantProps } from "class-variance-authority";

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-2 rounded-md text-sm font-medium transition-all",
  {
    variants: {
      variant: {
        default: "bg-primary text-primary-foreground hover:bg-primary/90",
        destructive: "bg-destructive text-white hover:bg-destructive/90",
        outline: "border bg-background hover:bg-accent",
        ghost: "hover:bg-accent hover:text-accent-foreground",
      },
      size: {
        default: "h-9 px-4 py-2",
        sm: "h-8 px-3",
        lg: "h-10 px-6",
        icon: "size-9",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
);

function Button({ className, variant, size, ...props }) {
  return (
    <button
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  );
}
```

**Usage in Code**:
```tsx
import { Button } from "@/components/ui/button";

<Button variant="default" size="lg">
  Start Meeting
</Button>
```

**Figma Mapping**:
- Figma Button Component → `<Button>`
- Variants in Figma → `variant` prop
- States (hover, pressed) → Handled by Tailwind classes

---

## 3. Frameworks & Build System

### Frontend Stack

| Technology | Version | Purpose |
|------------|---------|---------|
| **React** | 18.2.0 | UI framework |
| **TypeScript** | 5.2.2 | Type safety |
| **Vite** | 5.0.8 | Build tool & dev server |
| **TailwindCSS** | 3.3.6 | Styling framework |
| **Electron** | 39.2.3 | Desktop application wrapper |

### Build Configuration

**Vite Config** (`frontend/vite.config.ts`):

```typescript
import path from "path"
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  base: './',
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  server: {
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
      '/ws': {
        target: 'ws://localhost:8000',
        ws: true,
      },
    },
  },
});
```

**Key Features**:
- Path alias `@/*` maps to `src/*`
- Proxy API calls to FastAPI backend (port 8000)
- WebSocket proxy for real-time features

### TypeScript Configuration

**File**: `frontend/tsconfig.json`

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "jsx": "react-jsx",
    "strict": true,
    "baseUrl": ".",
    "paths": {
      "@/*": ["./src/*"]
    }
  }
}
```

**Import Path Convention**:
```tsx
// ✅ Use @ alias for src imports
import { Button } from "@/components/ui/button";
import { useMeetingStore } from "@/store/meetingStore";
import { cn } from "@/lib/utils";

// ❌ Avoid relative paths
import { Button } from "../../components/ui/button";
```

### Package Manager

**File**: `frontend/package.json`

```json
{
  "name": "macapy-frontend",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "electron:dev": "concurrently \"npm run dev\" \"npm run electron\""
  }
}
```

**Key Dependencies**:
- `@radix-ui/react-*` - UI primitives
- `class-variance-authority` - Component variants
- `clsx` + `tailwind-merge` - Utility class merging
- `lucide-react` - Icon library
- `zustand` - State management
- `socket.io-client` - WebSocket communication
- `react-hook-form` + `zod` - Form validation

---

## 4. Asset Management

### Current Asset Structure

**No dedicated assets folder exists yet.** The project uses:

1. **Inline SVG Components** (preferred for icons/logos)
2. **Lucide React Icons** (npm package)
3. **Design tokens in CSS** (colors, spacing)

### Recommended Asset Organization

```
frontend/
├── public/
│   ├── icons/           # Electron app icons
│   │   ├── icon.icns    # macOS
│   │   ├── icon.ico     # Windows
│   │   └── icon.png     # Linux
│   └── images/          # Static images
│       └── onboarding/
└── src/
    ├── assets/
    │   ├── images/      # Imported images
    │   └── videos/      # Demo videos
    └── components/
        └── ui/
            └── CapybaraLogo.tsx  # SVG components
```

### Asset Import Patterns

**For static images in public folder**:
```tsx
<img src="/images/logo.png" alt="macapy.io" />
```

**For imported assets (Vite optimization)**:
```tsx
import heroImage from '@/assets/images/hero.png';

<img src={heroImage} alt="Hero" />
```

**For SVG as React components** (preferred):
```tsx
// File: src/components/ui/CapybaraLogo.tsx
export function CapybaraLogo({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 100 100" className={className}>
      {/* SVG paths */}
    </svg>
  );
}

// Usage:
<CapybaraLogo className="w-8 h-8 text-brand-purple" />
```

### Asset Optimization

**Images**: Use Vite's built-in optimization
- Automatic image optimization on build
- Supports: `.png`, `.jpg`, `.webp`, `.svg`

**No CDN** currently configured - all assets bundled with app.

---

## 5. Icon System

### Primary Icon Library: Lucide React

**Package**: `lucide-react` (v0.554.0)

**Location**: Imported directly in components

**Usage Pattern**:
```tsx
import { Play, Square, Minus, X, MessageSquare, FileText } from "lucide-react";

<Button className="gap-2">
  <Play className="h-4 w-4" />
  Start Meeting
</Button>
```

### Icon Sizing Convention

| Context | Tailwind Class | Size |
|---------|----------------|------|
| Button icon | `h-4 w-4` | 16px |
| Header icon | `h-5 w-5` | 20px |
| Logo | `h-8 w-8` | 32px |
| Large icon | `h-6 w-6` | 24px |

### Commonly Used Icons

**File**: `frontend/src/components/MeetingHeader.tsx`
```tsx
import { Square, Play, Minus, X } from "lucide-react";

// Play icon for "Start Meeting"
<Play className="h-4 w-4" />

// Square icon for "Stop Meeting"
<Square className="h-4 w-4" />

// Window controls
<Minus className="h-4 w-4" /> // Minimize
<X className="h-4 w-4" /> // Close
```

**File**: `frontend/src/components/DocumentsSidebar.tsx`
```tsx
import { FileText, Table, File, Image, Upload } from "lucide-react";

// File type icons (colored)
<FileText className="w-5 h-5 text-red-400" />    // PDF
<Table className="w-5 h-5 text-green-400" />     // Excel
<File className="w-5 h-5 text-blue-400" />       // Word
<Image className="w-5 h-5 text-purple-400" />    // Images
```

### Custom Brand Icon

**File**: `frontend/src/components/ui/CapybaraLogo.tsx`

```tsx
export function CapybaraLogo({ className = "w-16 h-16" }: { className?: string }) {
  return (
    <svg viewBox="0 0 100 100" fill="none" className={className}>
      {/* Capybara outline paths */}
      <path d="M 50 15 Q 35 15 28 25..." stroke="currentColor" strokeWidth="3" />
      {/* ... */}
    </svg>
  );
}
```

**Usage**:
```tsx
<CapybaraLogo className="w-8 h-8 text-brand-purple" />
```

### Icon Naming Convention (Figma → Code)

| Figma Layer Name | Lucide Icon | Import |
|------------------|-------------|--------|
| icon/play | Play | `import { Play } from "lucide-react"` |
| icon/stop | Square | `import { Square } from "lucide-react"` |
| icon/file-text | FileText | `import { FileText } from "lucide-react"` |
| icon/upload | Upload | `import { Upload } from "lucide-react"` |
| icon/settings | Settings | `import { Settings } from "lucide-react"` |

**Search Icons**: [lucide.dev/icons](https://lucide.dev/icons)

---

## 6. Styling Approach

### CSS Methodology: Tailwind CSS Utility-First

**Philosophy**: Use Tailwind utility classes directly in JSX, avoiding custom CSS.

### Global Styles

**File**: `frontend/src/index.css`

```css
@tailwind base;
@tailwind components;
@tailwind utilities;

@layer base {
  :root {
    /* Design tokens */
  }

  * {
    @apply border-border;
  }

  body {
    @apply bg-background text-foreground;
  }
}
```

**No CSS Modules, Styled Components, or SCSS** - Pure Tailwind.

### Utility Class Merging

**File**: `frontend/src/lib/utils.ts`

```tsx
import { type ClassValue, clsx } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
```

**Purpose**: Merge Tailwind classes while handling conflicts.

**Usage**:
```tsx
import { cn } from "@/lib/utils";

function Card({ className }) {
  return (
    <div className={cn(
      "bg-card border rounded-xl p-6", // Base classes
      className // User overrides
    )}>
      {children}
    </div>
  );
}

// Usage: Overrides padding
<Card className="p-4" />
```

### Responsive Design

**Breakpoints** (Tailwind default):
```css
sm: 640px
md: 768px
lg: 1024px
xl: 1280px
2xl: 1536px
```

**Usage**:
```tsx
<div className="w-full md:w-1/2 lg:w-1/3">
  {/* Full width on mobile, half on tablet, third on desktop */}
</div>
```

**Note**: This is a **desktop-first application** (Electron), so responsive breakpoints are secondary.

### Dark Mode

**Current Implementation**: Dark mode only (no light mode toggle).

**Configuration** (`tailwind.config.js`):
```javascript
darkMode: ["class"]
```

**Usage**:
```tsx
// Dark mode classes are default
<div className="bg-slate-950 text-white">
  {/* Always dark */}
</div>
```

### Component Variant System

**Library**: `class-variance-authority` (CVA)

**Example** (`button.tsx`):
```tsx
import { cva, type VariantProps } from "class-variance-authority";

const buttonVariants = cva(
  "inline-flex items-center justify-center rounded-md transition-all",
  {
    variants: {
      variant: {
        default: "bg-primary text-white hover:bg-primary/90",
        outline: "border border-border hover:bg-accent",
        ghost: "hover:bg-accent",
      },
      size: {
        default: "h-9 px-4",
        sm: "h-8 px-3",
        lg: "h-10 px-6",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
);

function Button({ variant, size, className, ...props }: VariantProps<typeof buttonVariants>) {
  return (
    <button className={cn(buttonVariants({ variant, size }), className)} {...props} />
  );
}
```

**Figma Variants** → CVA variants:
- Figma: Button component with "Primary", "Secondary", "Ghost" variants
- Code: `variant="default"`, `variant="outline"`, `variant="ghost"`

---

## 7. Project Structure

```
agentic_assistant/
├── backend/                    # FastAPI Python backend
│   ├── app/
│   │   ├── api/               # REST endpoints
│   │   ├── models/            # SQLAlchemy models
│   │   ├── schemas/           # Pydantic schemas
│   │   └── services/          # Business logic
│   └── requirements.txt
│
├── frontend/                   # React + Electron frontend
│   ├── electron/              # Electron main process
│   ├── public/                # Static assets (icons)
│   ├── src/
│   │   ├── components/        # React components
│   │   │   ├── ui/           # shadcn/ui components
│   │   │   ├── MeetingHeader.tsx
│   │   │   ├── LiveTranscript.tsx
│   │   │   └── ...
│   │   ├── hooks/            # Custom React hooks
│   │   │   └── useWebSocket.ts
│   │   ├── store/            # Zustand state management
│   │   │   └── meetingStore.ts
│   │   ├── lib/              # Utilities
│   │   │   └── utils.ts      # cn() function
│   │   ├── App.tsx           # Main app component
│   │   └── index.css         # Global styles + tokens
│   ├── tailwind.config.js    # Tailwind configuration
│   ├── vite.config.ts        # Vite build config
│   ├── tsconfig.json         # TypeScript config
│   └── package.json
│
├── .claude/                   # Claude Code configuration
│   ├── agents/               # Agent-specific rules
│   │   └── figma-integration-rules.md  # This file
│   └── DESIGN_SYSTEM.md      # UI design guidelines
│
├── reference/                 # Project documentation
│   └── ROADMAP.md
│
├── .env                       # Environment variables
└── CLAUDE.md                  # Project overview
```

### Feature Organization Pattern

**No feature-based folders** - Components are organized by type:

```
src/
├── components/
│   ├── ui/                   # Reusable primitives
│   ├── MeetingHeader.tsx     # Feature component
│   └── LiveTranscript.tsx    # Feature component
├── hooks/                    # Custom hooks
├── store/                    # State management
└── lib/                      # Utilities
```

### File Naming Conventions

- **Components**: PascalCase (e.g., `MeetingHeader.tsx`)
- **Hooks**: camelCase with `use` prefix (e.g., `useWebSocket.ts`)
- **Utilities**: camelCase (e.g., `utils.ts`)
- **Types**: PascalCase (e.g., `Meeting`, `TranscriptSegment`)

---

## 8. State Management (Zustand)

**Location**: `frontend/src/store/meetingStore.ts`

### Pattern

```tsx
import { create } from 'zustand';

interface MeetingStore {
  currentMeeting: Meeting | null;
  transcript: TranscriptSegment[];

  setCurrentMeeting: (meeting: Meeting | null) => void;
  addTranscriptSegment: (segment: TranscriptSegment) => void;
}

export const useMeetingStore = create<MeetingStore>((set) => ({
  currentMeeting: null,
  transcript: [],

  setCurrentMeeting: (meeting) => set({ currentMeeting: meeting }),

  addTranscriptSegment: (segment) => set((state) => ({
    transcript: [...state.transcript, segment]
  })),
}));
```

### Usage in Components

```tsx
import { useMeetingStore } from "@/store/meetingStore";

function MeetingHeader() {
  const { currentMeeting, setCurrentMeeting } = useMeetingStore();

  return (
    <h1>{currentMeeting?.title || "No Active Meeting"}</h1>
  );
}
```

**No Redux, Context API, or Jotai** - Zustand only.

---

## 9. Real-Time Communication (WebSockets)

**Location**: `frontend/src/hooks/useWebSocket.ts`

### Pattern

```tsx
import { useEffect } from 'react';
import { io, Socket } from 'socket.io-client';
import { useMeetingStore } from '@/store/meetingStore';

export function useWebSocket(meetingId: string) {
  useEffect(() => {
    const socket: Socket = io('ws://localhost:8000');

    socket.on('transcript_update', (data) => {
      useMeetingStore.getState().addTranscriptSegment(data);
    });

    return () => {
      socket.disconnect();
    };
  }, [meetingId]);
}
```

### WebSocket Events (Backend Contract)

**Server → Client**:
- `transcript_update` - New transcript segment
- `summary_update` - New summary generated
- `suggestion_generated` - New AI suggestions
- `audio_level` - Audio capture monitoring
- `error` - Error messages

**Client → Server**:
- `join_meeting` - Connect to meeting room
- `leave_meeting` - Disconnect
- `mark_suggestion_used` - Track suggestion usage

---

## 10. Figma to Code Conversion Guidelines

### Step-by-Step Workflow

#### 1. **Analyze Figma Design Structure**

Identify:
- Components vs. instances
- Variants (button states, card types)
- Auto Layout (flexbox)
- Text styles
- Color styles

#### 2. **Map Figma Elements to Code**

| Figma Element | Code Equivalent |
|---------------|-----------------|
| Frame | `<div>` or semantic element (`<section>`, `<aside>`) |
| Auto Layout (Vertical) | `<div className="flex flex-col gap-4">` |
| Auto Layout (Horizontal) | `<div className="flex flex-row gap-2">` |
| Text | `<p>`, `<h1>`, `<span>` |
| Button Component | `<Button variant="...">` |
| Card Component | `<Card>` |
| Icon | `<Icon className="h-4 w-4" />` (Lucide React) |

#### 3. **Extract Design Tokens**

**Colors**:
```
Figma: #7c3aed (Purple) → Code: bg-brand-purple
Figma: #020617 (Dark)   → Code: bg-background
Figma: #f1f5f9 (Light)  → Code: text-foreground
```

**Spacing** (Auto Layout padding/gap):
```
Figma: 8px  → Code: gap-2 or p-2
Figma: 16px → Code: gap-4 or p-4
Figma: 32px → Code: gap-8 or p-8
```

**Border Radius**:
```
Figma: 8px  → Code: rounded-lg
Figma: 12px → Code: rounded-xl
Figma: 16px → Code: rounded-2xl
```

#### 4. **Convert Auto Layout to Flexbox**

**Figma Auto Layout Settings** → **Tailwind Classes**:

| Property | Figma Value | Tailwind Class |
|----------|-------------|----------------|
| Direction | Horizontal | `flex flex-row` |
| Direction | Vertical | `flex flex-col` |
| Spacing Between | 16px | `gap-4` |
| Padding | 16px all | `p-4` |
| Alignment (Main) | Space Between | `justify-between` |
| Alignment (Cross) | Center | `items-center` |
| Hug Contents | - | (default) |
| Fill Container | - | `flex-1` |

**Example**:
```tsx
// Figma: Auto Layout (Vertical, Gap 12px, Padding 16px)
<div className="flex flex-col gap-3 p-4">
  <h2>Title</h2>
  <p>Description</p>
</div>
```

#### 5. **Handle Component Variants**

**Figma Variants** → **TypeScript Union Types**:

```tsx
// Figma Component: Button with variants "Primary", "Secondary", "Ghost"
type ButtonVariant = "default" | "outline" | "ghost";

interface ButtonProps {
  variant?: ButtonVariant;
  children: React.ReactNode;
}

function Button({ variant = "default", children }: ButtonProps) {
  return (
    <button className={cn(buttonVariants({ variant }))}>
      {children}
    </button>
  );
}
```

#### 6. **Typography Conversion**

**Figma Text Styles** → **Tailwind Classes**:

| Figma Style | Font Size | Weight | Tailwind |
|-------------|-----------|--------|----------|
| Heading 1 | 24px | 700 | `text-2xl font-bold` |
| Heading 2 | 20px | 600 | `text-xl font-semibold` |
| Body | 14px | 400 | `text-sm` |
| Caption | 12px | 400 | `text-xs` |
| Label | 12px | 500 | `text-xs font-medium` |

**Example**:
```tsx
// Figma: "Heading 2" style (20px, Semi-Bold, #f1f5f9)
<h2 className="text-xl font-semibold text-foreground">
  Meeting Summary
</h2>
```

#### 7. **States & Interactions**

**Figma States** → **Tailwind Modifiers**:

| Figma State | Tailwind Modifier |
|-------------|-------------------|
| Default | Base classes |
| Hover | `hover:bg-primary/90` |
| Pressed | `active:scale-95` |
| Focused | `focus-visible:ring-2` |
| Disabled | `disabled:opacity-50` |

**Example**:
```tsx
// Figma: Button with hover state (bg changes from #7c3aed to #9333ea)
<Button className="bg-brand-purple hover:bg-primary-700 transition-colors">
  Submit
</Button>
```

#### 8. **Use Existing Components**

**Before creating new components, check**:
1. `frontend/src/components/ui/` for shadcn/ui primitives
2. `frontend/src/components/` for application components

**Example Decision Tree**:
```
Figma: Dialog with close button
↓
Check: Does `dialog.tsx` exist in `ui/`?
→ YES: Use <Dialog> component
→ NO: Create new component using Radix UI Dialog primitive
```

#### 9. **Code Generation Template**

```tsx
// Figma: [Component Name]
import { cn } from "@/lib/utils";
import { [Icon] } from "lucide-react";
import { Button } from "@/components/ui/button";

interface [ComponentName]Props {
  // Props based on Figma variants
  variant?: "default" | "compact";
  className?: string;
}

export function [ComponentName]({ variant = "default", className }: [ComponentName]Props) {
  return (
    <div className={cn(
      "flex flex-col gap-4 p-4", // Base layout from Figma Auto Layout
      "bg-card border border-border rounded-xl", // Background & borders
      className
    )}>
      {/* Child elements */}
    </div>
  );
}
```

---

## 11. Common Figma → Code Patterns

### Pattern 1: Card with Header & Content

**Figma Structure**:
```
Frame "Card"
├── Auto Layout (Vertical, Gap 16px)
│   ├── Frame "Header"
│   │   ├── Text "Title"
│   │   └── Icon "Close"
│   └── Frame "Content"
│       └── Text "Description"
```

**Code**:
```tsx
import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import { X } from "lucide-react";

<Card>
  <CardHeader>
    <CardTitle>Title</CardTitle>
    <button className="ml-auto">
      <X className="h-4 w-4" />
    </button>
  </CardHeader>
  <CardContent>
    <p>Description</p>
  </CardContent>
</Card>
```

### Pattern 2: Button with Icon

**Figma Structure**:
```
Component "Button"
├── Auto Layout (Horizontal, Gap 8px)
│   ├── Icon "Play"
│   └── Text "Start"
```

**Code**:
```tsx
import { Button } from "@/components/ui/button";
import { Play } from "lucide-react";

<Button className="gap-2">
  <Play className="h-4 w-4" />
  Start
</Button>
```

### Pattern 3: List with Hover States

**Figma Structure**:
```
Frame "List"
└── Auto Layout (Vertical, Gap 0)
    ├── Component "List Item" (Default)
    └── Component "List Item" (Hover)
```

**Code**:
```tsx
<div className="flex flex-col">
  {items.map((item) => (
    <button
      key={item.id}
      className="px-4 py-3 text-left hover:bg-accent transition-colors border-b border-border"
    >
      {item.name}
    </button>
  ))}
</div>
```

### Pattern 4: Badge/Status Indicator

**Figma Structure**:
```
Component "Badge"
├── Variant: "Success" (Green)
├── Variant: "Warning" (Yellow)
└── Variant: "Error" (Red)
```

**Code**:
```tsx
import { Badge } from "@/components/ui/badge";

<Badge variant="default">Success</Badge>
<Badge variant="secondary">Warning</Badge>
<Badge variant="destructive">Error</Badge>
```

---

## 12. Accessibility Checklist

When converting Figma to code, ensure:

- [ ] Semantic HTML (`<button>` not `<div>` for clickable elements)
- [ ] ARIA labels for icon-only buttons
- [ ] Keyboard navigation (Tab, Enter, Escape)
- [ ] Focus indicators (`focus-visible:ring-2`)
- [ ] Color contrast (WCAG AA: 4.5:1 for text)
- [ ] Alt text for images
- [ ] Form labels associated with inputs

**Example**:
```tsx
// ✅ Accessible button
<button
  aria-label="Close dialog"
  className="p-2 rounded-md focus-visible:ring-2 focus-visible:ring-primary"
>
  <X className="h-4 w-4" />
</button>

// ❌ Inaccessible button
<div onClick={handleClose}>
  <X />
</div>
```

---

## 13. Performance Considerations

### Code Splitting

Use lazy loading for routes:
```tsx
import { lazy, Suspense } from 'react';

const PostMeetingDashboard = lazy(() => import('@/components/PostMeetingDashboard'));

<Suspense fallback={<div>Loading...</div>}>
  <PostMeetingDashboard />
</Suspense>
```

### Avoid Re-renders

Use `React.memo` for expensive components:
```tsx
export const LiveTranscript = React.memo(function LiveTranscript() {
  // Component logic
});
```

### Optimize Images

For Figma-exported images:
```tsx
// Use WebP format when possible
<img src="/images/hero.webp" alt="Hero" loading="lazy" />
```

---

## 14. Testing Generated Code

### Manual Testing Checklist

- [ ] Component renders without errors
- [ ] Responsive behavior (if applicable)
- [ ] Hover states work
- [ ] Click handlers fire correctly
- [ ] Keyboard navigation functional
- [ ] Dark mode styles applied
- [ ] Performance (no jank on interactions)

### Visual Regression Testing

Compare Figma design to browser output:
1. Take screenshot of Figma frame
2. Take screenshot of rendered component (DevTools → Capture screenshot)
3. Compare pixel-by-pixel using overlay

---

## 15. Common Pitfalls & Solutions

### Pitfall 1: Over-nesting Divs

**Figma**: Many nested frames
**Code**: Flatten unnecessary wrappers

```tsx
// ❌ Too many divs
<div>
  <div>
    <div>
      <p>Text</p>
    </div>
  </div>
</div>

// ✅ Simplified
<p>Text</p>
```

### Pitfall 2: Hard-coded Values

**Figma**: Fixed 400px width
**Code**: Use responsive classes

```tsx
// ❌ Hard-coded
<div style={{ width: '400px' }}>

// ✅ Responsive
<div className="w-full max-w-md">
```

### Pitfall 3: Missing Accessibility

**Figma**: Visual design only
**Code**: Add ARIA and semantic HTML

```tsx
// ❌ Div button
<div onClick={handleClick}>Submit</div>

// ✅ Accessible button
<button
  type="button"
  aria-label="Submit form"
  onClick={handleClick}
>
  Submit
</button>
```

### Pitfall 4: Ignoring Existing Components

**Figma**: Custom button design
**Code**: Use existing `<Button>` component with variants

```tsx
// ❌ Reinventing the wheel
<div className="px-4 py-2 bg-purple-600 rounded-md">
  Click me
</div>

// ✅ Use existing component
<Button variant="default">Click me</Button>
```

---

## 16. Quick Reference

### Import Cheat Sheet

```tsx
// UI Components
import { Button } from "@/components/ui/button";
import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";

// Icons
import { Play, Square, X, Minus, FileText, Upload } from "lucide-react";

// Utilities
import { cn } from "@/lib/utils";

// State Management
import { useMeetingStore } from "@/store/meetingStore";

// Hooks
import { useWebSocket } from "@/hooks/useWebSocket";
```

### Color Classes Mapping

```tsx
// Backgrounds
bg-background        // #020617 (Slate 950)
bg-card              // #020617 (Slate 950)
bg-muted             // #1e293b (Slate 800)
bg-brand-purple      // #7c3aed (Purple 600)

// Text
text-foreground      // #f1f5f9 (Slate 100)
text-muted-foreground // #94a3b8 (Slate 400)
text-brand-purple    // #7c3aed (Purple 600)

// Borders
border-border        // #1e293b (Slate 800)
```

### Spacing Scale

```tsx
gap-2 = 8px
gap-3 = 12px
gap-4 = 16px
gap-6 = 24px
gap-8 = 32px

p-2 = padding: 8px
p-4 = padding: 16px
p-6 = padding: 24px
```

---

## 17. Resources & Documentation

- **shadcn/ui Docs**: https://ui.shadcn.com/
- **Tailwind CSS**: https://tailwindcss.com/docs
- **Radix UI**: https://www.radix-ui.com/primitives/docs
- **Lucide Icons**: https://lucide.dev/icons
- **Zustand**: https://zustand.docs.pmnd.rs/
- **Vite**: https://vitejs.dev/guide/
- **TypeScript**: https://www.typescriptlang.org/docs/

---

*Last Updated: November 24, 2025*
