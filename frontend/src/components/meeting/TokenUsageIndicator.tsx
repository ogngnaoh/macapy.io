/**
 * TokenUsageIndicator Component
 * Displays context window usage with progress bar
 */

import { useEffect, useCallback } from 'react';
import { useStore } from '@/store';
import { aiApi } from '@/services/api';
import { cn } from '@/lib/utils';
import { ProgressBar, Badge } from '@/components/common';

export function TokenUsageIndicator() {
  const { meeting, tokens, setTokenUsage } = useStore();

  // Fetch token usage periodically
  const fetchTokenUsage = useCallback(async () => {
    if (!meeting.current) return;

    try {
      const usage = await aiApi.getTokenUsage(meeting.current.id);
      setTokenUsage(usage.current_tokens, usage.max_tokens);
    } catch (error) {
      console.error('Failed to fetch token usage:', error);
    }
  }, [meeting.current, setTokenUsage]);

  useEffect(() => {
    if (meeting.status !== 'recording' && meeting.status !== 'paused') return;

    // Fetch immediately
    fetchTokenUsage();

    // Then every 30 seconds
    const interval = setInterval(fetchTokenUsage, 30000);

    return () => clearInterval(interval);
  }, [meeting.status, fetchTokenUsage]);

  const isActive = meeting.status === 'recording' || meeting.status === 'paused';

  if (!isActive) return null;

  const percentage = tokens.max > 0 ? (tokens.current / tokens.max) * 100 : 0;
  const variant = percentage >= 95 ? 'danger' : percentage >= 80 ? 'warning' : 'default';

  const formatTokens = (num: number): string => {
    if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
    if (num >= 1000) return `${(num / 1000).toFixed(1)}K`;
    return num.toString();
  };

  return (
    <div className="px-4 py-2 border-t border-border-default bg-bg-secondary">
      <div className="flex items-center gap-3">
        {/* Label */}
        <span className="text-xs text-text-dim font-mono shrink-0">
          Context:
        </span>

        {/* Progress bar */}
        <div className="flex-1">
          <ProgressBar
            value={tokens.current}
            max={tokens.max}
            variant={variant}
            size="sm"
          />
        </div>

        {/* Token count */}
        <span className={cn(
          'text-xs font-mono shrink-0',
          variant === 'danger' && 'text-accent-error',
          variant === 'warning' && 'text-accent-warning',
          variant === 'default' && 'text-text-muted'
        )}>
          {formatTokens(tokens.current)}/{formatTokens(tokens.max)}
        </span>

        {/* Warning badge */}
        {tokens.warning && (
          <Badge variant={percentage >= 95 ? 'error' : 'warning'}>
            {percentage >= 95 ? '[CRITICAL]' : '[WARN]'}
          </Badge>
        )}
      </div>
    </div>
  );
}

export default TokenUsageIndicator;
