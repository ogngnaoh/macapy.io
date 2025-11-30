/**
 * EmptyState Component
 * Terminal-styled placeholder for empty lists/content
 */

import { ReactNode } from 'react';
import { cn } from '@/lib/utils';
import { Button } from './Button';

export interface EmptyStateProps {
  icon?: ReactNode;
  title: string;
  description?: string;
  action?: {
    label: string;
    onClick: () => void;
  };
  className?: string;
}

export function EmptyState({
  icon,
  title,
  description,
  action,
  className,
}: EmptyStateProps) {
  return (
    <div
      className={cn(
        'flex flex-col items-center justify-center py-12 px-4 text-center',
        className
      )}
    >
      {/* Icon */}
      {icon && (
        <div className="text-4xl text-text-dim mb-4">
          {icon}
        </div>
      )}

      {/* Terminal-style empty message */}
      <div className="font-mono space-y-2">
        <p className="text-text-muted">
          <span className="text-text-dim">&gt;</span> {title}
        </p>
        {description && (
          <p className="text-sm text-text-dim">
            {description}
          </p>
        )}
      </div>

      {/* Action button */}
      {action && (
        <Button
          variant="primary"
          onClick={action.onClick}
          className="mt-6"
        >
          {action.label}
        </Button>
      )}

      {/* Blinking cursor */}
      <span className="mt-4 w-2 h-4 bg-text-primary animate-blink" />
    </div>
  );
}

export default EmptyState;
