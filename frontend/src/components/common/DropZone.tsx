/**
 * DropZone Component
 * Terminal-styled file drop zone for document upload
 */

import { useState, useCallback, DragEvent, ChangeEvent, useRef } from 'react';
import { cn } from '@/lib/utils';

export interface DropZoneProps {
  onDrop: (files: File[]) => void;
  accept?: string;
  maxSize?: number; // in bytes
  multiple?: boolean;
  disabled?: boolean;
  className?: string;
}

export function DropZone({
  onDrop,
  accept = '.pdf,.docx,.txt,.md',
  maxSize = 10 * 1024 * 1024, // 10MB default
  multiple = false,
  disabled = false,
  className,
}: DropZoneProps) {
  const [isDragging, setIsDragging] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const validateFiles = useCallback((files: FileList | File[]): File[] => {
    const validFiles: File[] = [];
    const fileArray = Array.from(files);

    for (const file of fileArray) {
      if (file.size > maxSize) {
        setError(`File "${file.name}" exceeds ${Math.round(maxSize / 1024 / 1024)}MB limit`);
        continue;
      }

      const ext = '.' + file.name.split('.').pop()?.toLowerCase();
      const acceptedExts = accept.split(',').map((a) => a.trim().toLowerCase());

      if (!acceptedExts.includes(ext) && accept !== '*') {
        setError(`File type "${ext}" not accepted`);
        continue;
      }

      validFiles.push(file);
    }

    return validFiles;
  }, [accept, maxSize]);

  const handleDragOver = useCallback((e: DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    if (!disabled) {
      setIsDragging(true);
    }
  }, [disabled]);

  const handleDragLeave = useCallback((e: DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragging(false);
  }, []);

  const handleDrop = useCallback((e: DragEvent) => {
    e.preventDefault();
    e.stopPropagation();
    setIsDragging(false);
    setError(null);

    if (disabled) return;

    const files = e.dataTransfer.files;
    const validFiles = validateFiles(files);

    if (validFiles.length > 0) {
      onDrop(multiple ? validFiles : [validFiles[0]]);
    }
  }, [disabled, multiple, onDrop, validateFiles]);

  const handleClick = useCallback(() => {
    if (!disabled && inputRef.current) {
      inputRef.current.click();
    }
  }, [disabled]);

  const handleChange = useCallback((e: ChangeEvent<HTMLInputElement>) => {
    setError(null);
    const files = e.target.files;
    if (files) {
      const validFiles = validateFiles(files);
      if (validFiles.length > 0) {
        onDrop(multiple ? validFiles : [validFiles[0]]);
      }
    }
    // Reset input
    if (inputRef.current) {
      inputRef.current.value = '';
    }
  }, [multiple, onDrop, validateFiles]);

  return (
    <div className={cn('w-full', className)}>
      <div
        onClick={handleClick}
        onDragOver={handleDragOver}
        onDragLeave={handleDragLeave}
        onDrop={handleDrop}
        className={cn(
          'relative border-2 border-dashed rounded-terminal p-6',
          'flex flex-col items-center justify-center gap-2',
          'cursor-pointer transition-all duration-150',
          'text-center',
          isDragging && !disabled && 'border-text-primary bg-text-primary/5',
          !isDragging && !disabled && 'border-border-default hover:border-text-primary/50 hover:bg-bg-tertiary/50',
          disabled && 'opacity-50 cursor-not-allowed',
          error && 'border-accent-error'
        )}
      >
        <input
          ref={inputRef}
          type="file"
          accept={accept}
          multiple={multiple}
          onChange={handleChange}
          disabled={disabled}
          className="hidden"
        />

        {/* Icon */}
        <div className="text-2xl text-text-muted">
          {isDragging ? '↓' : '📄'}
        </div>

        {/* Text */}
        <div className="space-y-1">
          <p className="text-sm text-text-primary font-mono">
            {isDragging ? 'Drop files here' : 'Drop files or click to upload'}
          </p>
          <p className="text-xs text-text-dim font-mono">
            {accept.replace(/\./g, '').replace(/,/g, ', ').toUpperCase()} • Max {Math.round(maxSize / 1024 / 1024)}MB
          </p>
        </div>
      </div>

      {/* Error message */}
      {error && (
        <p className="mt-2 text-xs text-accent-error font-mono">[ERR] {error}</p>
      )}
    </div>
  );
}

export default DropZone;
