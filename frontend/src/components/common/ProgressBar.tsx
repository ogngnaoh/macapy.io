/**
 * ProgressBar Component
 * Terminal-styled progress indicator for token usage, etc.
 */

import { cn } from '@/lib/utils';

export interface ProgressBarProps {
  value: number;
  max?: number;
  showLabel?: boolean;
  label?: string;
  variant?: 'default' | 'success' | 'warning' | 'danger';
  size?: 'sm' | 'md' | 'lg';
  className?: string;
}

export function ProgressBar({
  value,
  max = 100,
  showLabel = false,
  label,
  variant = 'default',
  size = 'md',
  className,
}: ProgressBarProps) {
  const percentage = Math.min(Math.max((value / max) * 100, 0), 100);

  // Auto-determine variant based on percentage if not explicitly set
  const autoVariant = variant === 'default'
    ? percentage >= 95
      ? 'danger'
      : percentage >= 80
        ? 'warning'
        : 'default'
    : variant;

  const variants = {
    default: 'bg-text-primary',
    success: 'bg-accent-success',
    warning: 'bg-accent-warning',
    danger: 'bg-accent-error',
  };

  const sizes = {
    sm: 'h-1',
    md: 'h-2',
    lg: 'h-3',
  };

  return (
    <div className={cn('w-full', className)}>
      {(showLabel || label) && (
        <div className="flex justify-between items-center mb-1">
          <span className="text-xs text-text-muted font-mono">
            {label || 'Progress'}
          </span>
          <span className={cn(
            'text-xs font-mono',
            autoVariant === 'danger' && 'text-accent-error',
            autoVariant === 'warning' && 'text-accent-warning',
            autoVariant === 'default' && 'text-text-muted',
            autoVariant === 'success' && 'text-accent-success',
          )}>
            {percentage.toFixed(1)}%
          </span>
        </div>
      )}
      <div
        className={cn(
          'w-full bg-bg-tertiary rounded-terminal overflow-hidden border border-border-default',
          sizes[size]
        )}
      >
        <div
          className={cn(
            'h-full transition-all duration-300 ease-out rounded-terminal',
            variants[autoVariant]
          )}
          style={{ width: `${percentage}%` }}
        />
      </div>
    </div>
  );
}

export default ProgressBar;
