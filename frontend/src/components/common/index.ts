/**
 * Common Components
 *
 * Reusable UI components shared across the application.
 * All components follow the terminal-inspired design system.
 */

// Core Components
export { Button } from './Button';
export type { ButtonProps } from './Button';

export { Input } from './Input';
export type { InputProps } from './Input';

export { Badge } from './Badge';
export type { BadgeProps } from './Badge';

export { Spinner } from './Spinner';
export type { SpinnerProps } from './Spinner';

export { ProgressBar } from './ProgressBar';
export type { ProgressBarProps } from './ProgressBar';

export { EmptyState } from './EmptyState';
export type { EmptyStateProps } from './EmptyState';

export { DropZone } from './DropZone';
export type { DropZoneProps } from './DropZone';

// Dialog Components
export { Dialog, DialogTrigger, DialogContent, DialogFooter, DialogClose } from './Dialog';
export type { DialogProps } from './Dialog';

// Toast Components
export { ToastProvider, useToast } from './Toast';
export type { ToastProps } from './Toast';

// Error Handling
export { ErrorBoundary } from './ErrorBoundary';

// Loading States
export { Skeleton, SkeletonCard, SkeletonList } from './Skeleton';

// Icons
export { Icon } from './Icon';
export type { IconProps, IconName } from './Icon';
