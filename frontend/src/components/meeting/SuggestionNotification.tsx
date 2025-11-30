/**
 * SuggestionNotification Component
 * Floating notification for auto-detected questions with response suggestions
 */

import { useState, useEffect, useCallback } from 'react';
import { useStore } from '@/store';
import { cn, copyToClipboard } from '@/lib/utils';
import { Button, Badge } from '@/components/common';

export function SuggestionNotification() {
  const { suggestion, dismissActiveSuggestion } = useStore();
  const [copiedIndex, setCopiedIndex] = useState<number | null>(null);
  const [timeRemaining, setTimeRemaining] = useState(30);

  const activeSuggestion = suggestion.active;

  // Auto-dismiss timer
  useEffect(() => {
    if (!activeSuggestion) {
      setTimeRemaining(30);
      return;
    }

    setTimeRemaining(30);
    const interval = setInterval(() => {
      setTimeRemaining((prev) => {
        if (prev <= 1) {
          dismissActiveSuggestion();
          return 30;
        }
        return prev - 1;
      });
    }, 1000);

    return () => clearInterval(interval);
  }, [activeSuggestion, dismissActiveSuggestion]);

  const handleCopy = useCallback(async (text: string, index: number) => {
    const success = await copyToClipboard(text);
    if (success) {
      setCopiedIndex(index);
      setTimeout(() => setCopiedIndex(null), 2000);
    }
  }, []);

  if (!activeSuggestion) return null;

  return (
    <div
      className={cn(
        'fixed top-20 right-4 w-80 max-w-[calc(100vw-2rem)]',
        'bg-bg-secondary border border-accent-cyan/50 rounded-terminal',
        'shadow-terminal-lg animate-slide-up z-50'
      )}
    >
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-2 border-b border-border-default">
        <div className="flex items-center gap-2">
          <Badge variant="info">[SUGGESTION]</Badge>
          <span className="text-xs text-text-dim font-mono">{timeRemaining}s</span>
        </div>
        <button
          onClick={dismissActiveSuggestion}
          className="text-text-dim hover:text-text-primary transition-colors"
        >
          <span className="sr-only">Dismiss</span>
          <span className="text-lg">&times;</span>
        </button>
      </div>

      {/* Question detected */}
      <div className="px-4 py-3 border-b border-border-default">
        <span className="text-xs text-text-dim font-mono block mb-1">
          Question detected:
        </span>
        <p className="text-sm text-text-primary font-mono">
          "{activeSuggestion.question}"
        </p>
      </div>

      {/* Suggested responses */}
      <div className="p-4 space-y-2">
        <span className="text-xs text-text-dim font-mono block mb-2">
          Suggested responses:
        </span>
        {activeSuggestion.suggestions.map((suggestion, index) => (
          <button
            key={index}
            onClick={() => handleCopy(suggestion, index)}
            className={cn(
              'w-full text-left p-3 rounded-terminal',
              'bg-bg-tertiary border border-border-default',
              'text-sm text-text-muted font-mono',
              'transition-all duration-150',
              'hover:border-text-primary/50 hover:bg-bg-secondary',
              copiedIndex === index && 'border-accent-success bg-accent-success/10'
            )}
          >
            <div className="flex items-start gap-2">
              <span className="text-text-dim text-xs shrink-0">
                {index + 1}.
              </span>
              <span className="flex-1">
                {suggestion}
              </span>
            </div>
            {copiedIndex === index && (
              <span className="text-xs text-accent-success mt-1 block">
                Copied to clipboard!
              </span>
            )}
          </button>
        ))}
      </div>

      {/* Footer */}
      <div className="px-4 py-2 border-t border-border-default">
        <span className="text-xs text-text-dim font-mono">
          Click a suggestion to copy
        </span>
      </div>

      {/* Queue indicator */}
      {suggestion.queue.length > 0 && (
        <div className="px-4 py-2 border-t border-border-default bg-bg-tertiary">
          <span className="text-xs text-text-dim font-mono">
            +{suggestion.queue.length} more suggestion{suggestion.queue.length > 1 ? 's' : ''} queued
          </span>
        </div>
      )}
    </div>
  );
}

export default SuggestionNotification;
