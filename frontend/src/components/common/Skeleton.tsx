/**
 * Skeleton Component
 * Loading placeholder with shimmer animation
 */

import { cn } from '@/lib/utils';

interface SkeletonProps {
  className?: string;
  variant?: 'text' | 'circular' | 'rectangular';
  width?: string | number;
  height?: string | number;
  lines?: number;
}

export function Skeleton({
  className,
  variant = 'rectangular',
  width,
  height,
  lines = 1,
}: SkeletonProps) {
  const baseStyles = 'animate-pulse bg-bg-tertiary';

  const variantStyles = {
    text: 'rounded h-4',
    circular: 'rounded-full',
    rectangular: 'rounded-terminal',
  };

  const style: React.CSSProperties = {
    width: width ?? (variant === 'circular' ? height : '100%'),
    height: height ?? (variant === 'text' ? '1rem' : variant === 'circular' ? width : '100%'),
  };

  if (variant === 'text' && lines > 1) {
    return (
      <div className={cn('space-y-2', className)}>
        {Array.from({ length: lines }).map((_, i) => (
          <div
            key={i}
            className={cn(baseStyles, variantStyles.text)}
            style={{
              ...style,
              width: i === lines - 1 ? '75%' : style.width,
            }}
          />
        ))}
      </div>
    );
  }

  return (
    <div
      className={cn(baseStyles, variantStyles[variant], className)}
      style={style}
    />
  );
}

/**
 * SkeletonCard - Pre-built skeleton for card-like content
 */
export function SkeletonCard({ className }: { className?: string }) {
  return (
    <div className={cn('p-4 bg-bg-secondary border border-border-default rounded-terminal', className)}>
      <div className="flex items-start gap-3">
        <Skeleton variant="circular" width={40} height={40} />
        <div className="flex-1 space-y-2">
          <Skeleton variant="text" width="60%" />
          <Skeleton variant="text" width="40%" />
        </div>
      </div>
      <div className="mt-4">
        <Skeleton variant="text" lines={3} />
      </div>
    </div>
  );
}

/**
 * SkeletonList - Pre-built skeleton for list content
 */
export function SkeletonList({ count = 3, className }: { count?: number; className?: string }) {
  return (
    <div className={cn('space-y-2', className)}>
      {Array.from({ length: count }).map((_, i) => (
        <div key={i} className="flex items-center gap-3 p-2">
          <Skeleton variant="circular" width={32} height={32} />
          <div className="flex-1">
            <Skeleton variant="text" width="70%" />
          </div>
        </div>
      ))}
    </div>
  );
}

export default Skeleton;
