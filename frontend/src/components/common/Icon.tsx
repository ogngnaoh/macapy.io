/**
 * Icon Component
 * Unified icon system with consistent styling
 */

import { cn } from '@/lib/utils';
import { iconPaths, type IconName } from './icons';

export interface IconProps {
  name: IconName;
  size?: 'xs' | 'sm' | 'md' | 'lg' | 'xl';
  className?: string;
  strokeWidth?: number;
  'aria-label'?: string;
}

const sizeMap = {
  xs: 'w-3 h-3',
  sm: 'w-4 h-4',
  md: 'w-5 h-5',
  lg: 'w-6 h-6',
  xl: 'w-8 h-8',
};

export function Icon({
  name,
  size = 'md',
  className,
  strokeWidth = 1.5,
  'aria-label': ariaLabel,
}: IconProps) {
  const path = iconPaths[name];

  if (!path) {
    console.warn(`Icon "${name}" not found`);
    return null;
  }

  // Handle multi-path icons (paths separated by space before M)
  const paths = path.split(/(?=M)/g).filter(Boolean);

  return (
    <svg
      className={cn(sizeMap[size], className)}
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-label={ariaLabel}
      role={ariaLabel ? 'img' : 'presentation'}
    >
      {paths.map((d, i) => (
        <path key={i} d={d.trim()} />
      ))}
    </svg>
  );
}

export type { IconName };
export default Icon;
