/**
 * Dialog Component
 * Terminal-styled modal dialogs using Radix Dialog
 */

import * as DialogPrimitive from '@radix-ui/react-dialog';
import { cn } from '@/lib/utils';
import { ReactNode } from 'react';

export interface DialogProps {
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  children: ReactNode;
}

export function Dialog({ open, onOpenChange, children }: DialogProps) {
  return (
    <DialogPrimitive.Root open={open} onOpenChange={onOpenChange}>
      {children}
    </DialogPrimitive.Root>
  );
}

export function DialogTrigger({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <DialogPrimitive.Trigger className={className} asChild>
      {children}
    </DialogPrimitive.Trigger>
  );
}

export function DialogContent({
  children,
  className,
  title,
  description,
}: {
  children: ReactNode;
  className?: string;
  title?: string;
  description?: string;
}) {
  return (
    <DialogPrimitive.Portal>
      <DialogPrimitive.Overlay
        className={cn(
          'fixed inset-0 bg-bg-primary/80 backdrop-blur-sm z-50',
          'data-[state=open]:animate-fade-in',
          'data-[state=closed]:animate-fade-out'
        )}
      />
      <DialogPrimitive.Content
        className={cn(
          'fixed left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 z-50',
          'w-full max-w-md',
          'bg-bg-secondary border border-border-default rounded-terminal',
          'shadow-terminal-lg',
          'data-[state=open]:animate-slide-up',
          'data-[state=closed]:animate-fade-out',
          'focus:outline-none',
          className
        )}
      >
        {/* Terminal-style header */}
        <div className="flex items-center justify-between px-4 py-2 border-b border-border-default">
          <div className="flex items-center gap-2">
            <span className="w-3 h-3 rounded-full bg-accent-error/80" />
            <span className="w-3 h-3 rounded-full bg-accent-warning/80" />
            <span className="w-3 h-3 rounded-full bg-accent-success/80" />
          </div>
          {title && (
            <DialogPrimitive.Title className="text-sm font-mono text-text-muted">
              {title}
            </DialogPrimitive.Title>
          )}
          <DialogPrimitive.Close className="text-text-dim hover:text-text-primary transition-colors">
            <span className="sr-only">Close</span>
            <span className="text-lg">&times;</span>
          </DialogPrimitive.Close>
        </div>

        {/* Content */}
        <div className="p-4">
          {description && (
            <DialogPrimitive.Description className="text-sm text-text-muted font-mono mb-4">
              {description}
            </DialogPrimitive.Description>
          )}
          {children}
        </div>
      </DialogPrimitive.Content>
    </DialogPrimitive.Portal>
  );
}

export function DialogFooter({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn('flex items-center justify-end gap-2 mt-4 pt-4 border-t border-border-default', className)}>
      {children}
    </div>
  );
}

export function DialogClose({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <DialogPrimitive.Close className={className} asChild>
      {children}
    </DialogPrimitive.Close>
  );
}

export default Dialog;
