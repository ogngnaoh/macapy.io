/**
 * Spinner Component
 * Terminal-style loading indicators
 */

import { cn } from '@/lib/utils';

export interface SpinnerProps {
  size?: 'sm' | 'md' | 'lg';
  variant?: 'default' | 'dots' | 'cursor';
  className?: string;
}

export function Spinner({ size = 'md', variant = 'default', className }: SpinnerProps) {
  const sizes = {
    sm: 'w-3 h-3',
    md: 'w-4 h-4',
    lg: 'w-6 h-6',
  };

  if (variant === 'cursor') {
    return (
      <span
        className={cn(
          'inline-block bg-text-primary animate-blink',
          size === 'sm' && 'w-1.5 h-3',
          size === 'md' && 'w-2 h-4',
          size === 'lg' && 'w-2.5 h-5',
          className
        )}
      />
    );
  }

  if (variant === 'dots') {
    return (
      <span className={cn('inline-flex gap-0.5', className)}>
        {[0, 1, 2].map((i) => (
          <span
            key={i}
            className={cn(
              'rounded-full bg-text-primary',
              size === 'sm' && 'w-1 h-1',
              size === 'md' && 'w-1.5 h-1.5',
              size === 'lg' && 'w-2 h-2',
            )}
            style={{
              animation: `pulse 1.4s ease-in-out ${i * 0.2}s infinite`,
            }}
          />
        ))}
      </span>
    );
  }

  return (
    <span
      className={cn(
        sizes[size],
        'border-2 border-current border-t-transparent rounded-full animate-spin',
        'text-text-primary',
        className
      )}
    />
  );
}

export default Spinner;
