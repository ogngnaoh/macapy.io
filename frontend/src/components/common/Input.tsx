/**
 * Input Component
 * Terminal-styled text input with prompt prefix support
 */

import { forwardRef, InputHTMLAttributes } from 'react';
import { cn } from '@/lib/utils';

export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  showPrompt?: boolean;
  icon?: React.ReactNode;
  error?: string;
}

export const Input = forwardRef<HTMLInputElement, InputProps>(
  ({ className, showPrompt = false, icon, error, ...props }, ref) => {
    return (
      <div className="w-full">
        <div className={cn(
          'flex items-center gap-2',
          'bg-bg-primary border rounded-terminal',
          'transition-all duration-150 ease-out',
          'focus-within:border-border-focus focus-within:shadow-terminal',
          error ? 'border-accent-error' : 'border-border-default',
        )}>
          {showPrompt && (
            <span className="pl-3 text-accent-success font-bold select-none">&gt;</span>
          )}
          {icon && (
            <span className="pl-3 text-text-muted">{icon}</span>
          )}
          <input
            ref={ref}
            className={cn(
              'flex-1 w-full px-3 py-2 bg-transparent',
              'text-text-primary text-sm font-mono',
              'placeholder:text-text-dim',
              'outline-none border-none',
              showPrompt && 'pl-0',
              icon && 'pl-0',
              className
            )}
            {...props}
          />
        </div>
        {error && (
          <p className="mt-1 text-xs text-accent-error">{error}</p>
        )}
      </div>
    );
  }
);

Input.displayName = 'Input';

export default Input;
