/**
 * Button Component
 * Terminal-styled button with variants and sizes
 */

import { forwardRef, ButtonHTMLAttributes } from 'react';
import { cn } from '@/lib/utils';

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'default' | 'primary' | 'success' | 'danger' | 'ghost';
  size?: 'sm' | 'md' | 'lg';
  isLoading?: boolean;
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = 'default', size = 'md', isLoading, disabled, children, ...props }, ref) => {
    const baseStyles = `
      inline-flex items-center justify-center font-mono
      transition-all duration-150 ease-out
      active:scale-[0.98]
      disabled:opacity-50 disabled:cursor-not-allowed disabled:active:scale-100
    `;

    const variants = {
      default: `
        bg-bg-tertiary border border-border-default rounded-terminal
        text-text-primary
        hover:bg-bg-secondary hover:border-border-focus hover:shadow-terminal
        disabled:hover:bg-bg-tertiary disabled:hover:border-border-default
      `,
      primary: `
        bg-text-primary/10 border border-text-primary/30 rounded-terminal
        text-text-primary
        hover:bg-text-primary/20 hover:border-text-primary
        disabled:hover:bg-text-primary/10
      `,
      success: `
        bg-accent-success/10 border border-accent-success/30 rounded-terminal
        text-accent-success
        hover:bg-accent-success/20 hover:border-accent-success
        disabled:hover:bg-accent-success/10
      `,
      danger: `
        bg-accent-error/10 border border-accent-error/30 rounded-terminal
        text-accent-error
        hover:bg-accent-error/20 hover:border-accent-error
        disabled:hover:bg-accent-error/10
      `,
      ghost: `
        bg-transparent border border-transparent rounded-terminal
        text-text-muted
        hover:bg-bg-tertiary hover:text-text-primary
      `,
    };

    const sizes = {
      sm: 'px-2 py-1 text-xs',
      md: 'px-4 py-1.5 text-sm',
      lg: 'px-6 py-2 text-sm',
    };

    return (
      <button
        ref={ref}
        className={cn(baseStyles, variants[variant], sizes[size], className)}
        disabled={disabled || isLoading}
        {...props}
      >
        {isLoading ? (
          <>
            <span className="w-3 h-3 mr-2 border-2 border-current border-t-transparent rounded-full animate-spin" />
            Loading...
          </>
        ) : (
          children
        )}
      </button>
    );
  }
);

Button.displayName = 'Button';

export default Button;
