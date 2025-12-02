/**
 * MeetingCard Component
 * Summary card for a past meeting in the list
 */

import { Meeting } from '@/services/api';
import { cn, formatDate, formatDuration } from '@/lib/utils';
import { Badge } from '@/components/common';

export interface MeetingCardProps {
  meeting: Meeting;
  isSelected?: boolean;
  onClick: () => void;
  onDelete?: () => void;
}

export function MeetingCard({ meeting, isSelected, onClick, onDelete }: MeetingCardProps) {
  const duration = meeting.end_time
    ? Math.floor((new Date(meeting.end_time).getTime() - new Date(meeting.start_time).getTime()) / 1000)
    : 0;

  const statusVariant = {
    PENDING: 'warning',
    IN_PROGRESS: 'info',
    COMPLETED: 'success',
  }[meeting.status] as 'warning' | 'info' | 'success';

  return (
    <div
      onClick={onClick}
      className={cn(
        'p-4 border rounded-terminal cursor-pointer',
        'transition-all duration-150',
        isSelected
          ? 'bg-text-primary/10 border-text-primary'
          : 'bg-bg-secondary border-border-default hover:border-text-primary/50 hover:bg-bg-tertiary'
      )}
    >
      {/* Header */}
      <div className="flex items-start justify-between gap-2 mb-2">
        <h3 className="text-sm font-mono font-medium text-text-primary truncate flex-1">
          {meeting.title || 'Untitled Meeting'}
        </h3>
        <Badge variant={statusVariant} className="shrink-0">
          {meeting.status}
        </Badge>
      </div>

      {/* Metadata */}
      <div className="flex items-center gap-3 text-xs text-text-dim font-mono">
        <span>{formatDate(meeting.start_time)}</span>
        {duration > 0 && (
          <>
            <span className="text-border-default">•</span>
            <span>{formatDuration(duration)}</span>
          </>
        )}
        {meeting.platform && (
          <>
            <span className="text-border-default">•</span>
            <span className="capitalize">{meeting.platform}</span>
          </>
        )}
      </div>

      {/* Delete button */}
      {onDelete && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onDelete();
          }}
          className="mt-2 text-xs text-text-dim hover:text-accent-error transition-colors font-mono"
        >
          [delete]
        </button>
      )}
    </div>
  );
}

export default MeetingCard;
