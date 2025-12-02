/**
 * Toast Component
 * Terminal-styled notifications using Radix Toast
 */

import * as ToastPrimitive from '@radix-ui/react-toast';
import { cn } from '@/lib/utils';
import { createContext, useContext, useState, useCallback, ReactNode } from 'react';

export interface ToastProps {
  id: string;
  title?: string;
  description?: string;
  variant?: 'default' | 'success' | 'warning' | 'error';
  duration?: number;
}

interface ToastContextType {
  toast: (props: Omit<ToastProps, 'id'>) => void;
  dismiss: (id: string) => void;
}

const ToastContext = createContext<ToastContextType | null>(null);

export function useToast() {
  const context = useContext(ToastContext);
  if (!context) {
    throw new Error('useToast must be used within a ToastProvider');
  }
  return context;
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<ToastProps[]>([]);

  const toast = useCallback((props: Omit<ToastProps, 'id'>) => {
    const id = Math.random().toString(36).substring(2, 9);
    setToasts((prev) => [...prev, { ...props, id }]);
  }, []);

  const dismiss = useCallback((id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  return (
    <ToastContext.Provider value={{ toast, dismiss }}>
      <ToastPrimitive.Provider swipeDirection="right">
        {children}
        {toasts.map((t) => (
          <Toast key={t.id} {...t} onOpenChange={(open) => !open && dismiss(t.id)} />
        ))}
        <ToastViewport />
      </ToastPrimitive.Provider>
    </ToastContext.Provider>
  );
}

function Toast({
  title,
  description,
  variant = 'default',
  duration = 5000,
  onOpenChange,
}: ToastProps & { onOpenChange: (open: boolean) => void }) {
  const variants = {
    default: 'border-border-default',
    success: 'border-accent-success/50',
    warning: 'border-accent-warning/50',
    error: 'border-accent-error/50',
  };

  const icons = {
    default: '[INFO]',
    success: '[OK]',
    warning: '[WARN]',
    error: '[ERR]',
  };

  const iconColors = {
    default: 'text-text-primary',
    success: 'text-accent-success',
    warning: 'text-accent-warning',
    error: 'text-accent-error',
  };

  return (
    <ToastPrimitive.Root
      duration={duration}
      onOpenChange={onOpenChange}
      className={cn(
        'bg-bg-secondary border rounded-terminal p-4 shadow-terminal',
        'data-[state=open]:animate-slide-up',
        'data-[state=closed]:animate-fade-out',
        'data-[swipe=move]:translate-x-[var(--radix-toast-swipe-move-x)]',
        'data-[swipe=cancel]:translate-x-0 data-[swipe=cancel]:transition-transform',
        'data-[swipe=end]:animate-fade-out',
        variants[variant]
      )}
    >
      <div className="flex items-start gap-3">
        <span className={cn('text-xs font-mono font-bold', iconColors[variant])}>
          {icons[variant]}
        </span>
        <div className="flex-1 min-w-0">
          {title && (
            <ToastPrimitive.Title className="text-sm font-medium text-text-primary font-mono">
              {title}
            </ToastPrimitive.Title>
          )}
          {description && (
            <ToastPrimitive.Description className="mt-1 text-xs text-text-muted font-mono">
              {description}
            </ToastPrimitive.Description>
          )}
        </div>
        <ToastPrimitive.Close className="text-text-dim hover:text-text-primary transition-colors">
          <span className="sr-only">Close</span>
          <span className="text-lg">&times;</span>
        </ToastPrimitive.Close>
      </div>
    </ToastPrimitive.Root>
  );
}

function ToastViewport() {
  return (
    <ToastPrimitive.Viewport
      className={cn(
        'fixed bottom-4 right-4 flex flex-col gap-2 w-80 max-w-[100vw] z-50',
        'outline-none'
      )}
    />
  );
}

export default Toast;
