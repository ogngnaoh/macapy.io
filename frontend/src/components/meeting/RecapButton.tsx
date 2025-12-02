/**
 * RecapButton Component
 * Quick 30-second recap button with modal display
 */

import { useState, useCallback } from 'react';
import { useStore } from '@/store';
import { aiApi, RecapResponse } from '@/services/api';
import { cn } from '@/lib/utils';
import { Button, Spinner, Dialog, DialogContent, DialogFooter, DialogClose } from '@/components/common';

export function RecapButton() {
  const { meeting } = useStore();
  const [isOpen, setIsOpen] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [recap, setRecap] = useState<RecapResponse | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleRecap = useCallback(async () => {
    if (!meeting.current) return;

    setIsLoading(true);
    setError(null);

    try {
      const response = await aiApi.getRecap(meeting.current.id, 30);
      setRecap(response);
      setIsOpen(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to generate recap');
      setIsOpen(true);
    } finally {
      setIsLoading(false);
    }
  }, [meeting.current]);

  const isActive = meeting.status === 'recording' || meeting.status === 'paused';

  if (!isActive) return null;

  return (
    <>
      <Button
        data-testid="recap-button"
        variant="ghost"
        size="sm"
        onClick={handleRecap}
        disabled={isLoading}
        className="text-accent-cyan"
        title="30-second recap (⌘+Shift+R)"
      >
        {isLoading ? (
          <>
            <Spinner size="sm" className="mr-2" />
            Generating...
          </>
        ) : (
          '30s Recap'
        )}
      </Button>

      <Dialog open={isOpen} onOpenChange={setIsOpen}>
        <DialogContent title="30-Second Recap">
          {error ? (
            <div className="text-accent-error text-sm font-mono">
              [ERR] {error}
            </div>
          ) : recap ? (
            <div className="space-y-4">
              {/* Recap content */}
              <div className="bg-bg-tertiary border border-border-default rounded-terminal p-4">
                <pre className="text-sm text-text-primary font-mono whitespace-pre-wrap">
                  {recap.recap}
                </pre>
              </div>

              {/* Metadata */}
              <div className="flex items-center justify-between text-xs text-text-dim font-mono">
                <span>
                  {recap.transcript_count} transcript{recap.transcript_count !== 1 ? 's' : ''} analyzed
                </span>
                <span>
                  {recap.tokens_used} tokens used
                </span>
              </div>

              {/* Time range */}
              {recap.time_range && recap.time_range.start && (
                <div className="text-xs text-text-dim font-mono">
                  Time range: {new Date(recap.time_range.start).toLocaleTimeString()} - {recap.time_range.end ? new Date(recap.time_range.end).toLocaleTimeString() : 'now'}
                </div>
              )}
            </div>
          ) : (
            <div className="flex items-center justify-center py-8">
              <Spinner size="lg" />
            </div>
          )}

          <DialogFooter>
            <DialogClose>
              <Button variant="default">Close</Button>
            </DialogClose>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

export default RecapButton;
