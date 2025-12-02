/**
 * MeetingList Component
 * Virtualized list of past meetings
 */

import { useRef, useCallback } from 'react';
import { useVirtualizer } from '@tanstack/react-virtual';
import { Meeting } from '@/services/api';
import { MeetingCard } from './MeetingCard';
import { EmptyState, Spinner } from '@/components/common';

export interface MeetingListProps {
  meetings: Meeting[];
  selectedId: string | null;
  onSelect: (meeting: Meeting) => void;
  onDelete?: (id: string) => void;
  isLoading?: boolean;
}

export function MeetingList({
  meetings,
  selectedId,
  onSelect,
  onDelete,
  isLoading,
}: MeetingListProps) {
  const parentRef = useRef<HTMLDivElement>(null);

  const virtualizer = useVirtualizer({
    count: meetings.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 100, // Estimated row height
    overscan: 5,
  });

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-12">
        <Spinner size="lg" />
      </div>
    );
  }

  if (meetings.length === 0) {
    return (
      <EmptyState
        icon="📋"
        title="No meetings found"
        description="Start a meeting to see it appear in your history"
      />
    );
  }

  return (
    <div
      ref={parentRef}
      data-testid="meeting-list"
      className="flex-1 overflow-auto"
      style={{ height: '100%' }}
    >
      <div
        style={{
          height: `${virtualizer.getTotalSize()}px`,
          width: '100%',
          position: 'relative',
        }}
      >
        {virtualizer.getVirtualItems().map((virtualRow) => {
          const meeting = meetings[virtualRow.index];
          return (
            <div
              key={meeting.id}
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                width: '100%',
                height: `${virtualRow.size}px`,
                transform: `translateY(${virtualRow.start}px)`,
              }}
              className="p-2"
            >
              <MeetingCard
                meeting={meeting}
                isSelected={selectedId === meeting.id}
                onClick={() => onSelect(meeting)}
                onDelete={onDelete ? () => onDelete(meeting.id) : undefined}
              />
            </div>
          );
        })}
      </div>
    </div>
  );
}

export default MeetingList;
