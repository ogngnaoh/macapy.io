/**
 * Badge Component
 * Terminal-styled status badges
 */

import { HTMLAttributes } from 'react';
import { cn } from '@/lib/utils';

export interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  variant?: 'default' | 'success' | 'warning' | 'error' | 'info';
}

export function Badge({ className, variant = 'default', children, ...props }: BadgeProps) {
  const variants = {
    default: 'bg-bg-tertiary text-text-muted border-border-default',
    success: 'bg-accent-success/20 text-accent-success border-accent-success/30',
    warning: 'bg-accent-warning/20 text-accent-warning border-accent-warning/30',
    error: 'bg-accent-error/20 text-accent-error border-accent-error/30',
    info: 'bg-accent-cyan/20 text-accent-cyan border-accent-cyan/30',
  };

  return (
    <span
      className={cn(
        'inline-flex items-center px-2 py-0.5 rounded text-xs font-medium font-mono border',
        variants[variant],
        className
      )}
      {...props}
    >
      {children}
    </span>
  );
}

export default Badge;
