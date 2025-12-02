/**
 * SearchBar Component
 * Search through meeting transcripts with debounced input
 */

import { useEffect, useState, useCallback } from 'react';
import { cn, debounce } from '@/lib/utils';
import { Input, Spinner } from '@/components/common';

export interface SearchBarProps {
  value: string;
  onChange: (value: string) => void;
  isLoading?: boolean;
  resultCount?: number;
  placeholder?: string;
  className?: string;
}

export function SearchBar({
  value,
  onChange,
  isLoading = false,
  resultCount,
  placeholder = 'Search meetings...',
  className,
}: SearchBarProps) {
  const [localValue, setLocalValue] = useState(value);

  // Debounced onChange
  const debouncedOnChange = useCallback(
    debounce((val: string) => onChange(val), 300),
    [onChange]
  );

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setLocalValue(e.target.value);
    debouncedOnChange(e.target.value);
  };

  // Sync with external value
  useEffect(() => {
    setLocalValue(value);
  }, [value]);

  return (
    <div className={cn('relative', className)}>
      <div className="relative">
        <Input
          data-testid="search-input"
          value={localValue}
          onChange={handleChange}
          placeholder={placeholder}
          showPrompt
          className="pr-10"
        />
        {isLoading && (
          <div className="absolute right-3 top-1/2 -translate-y-1/2">
            <Spinner size="sm" />
          </div>
        )}
      </div>

      {/* Result count */}
      {resultCount !== undefined && localValue && (
        <div className="mt-2 text-xs text-text-dim font-mono">
          {resultCount === 0
            ? 'No matches found'
            : `${resultCount} meeting${resultCount !== 1 ? 's' : ''} found`}
        </div>
      )}
    </div>
  );
}

export default SearchBar;
