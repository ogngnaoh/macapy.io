import { cn } from '@/lib/utils';
import { useStore, ViewType } from '@/store';
import { Icon, type IconName } from '@/components/common';

type NavItem = {
  id: string;
  label: string;
  icon: IconName;
  viewType?: ViewType;  // Only 'meeting' and 'history' are supported views
};

const navItems: NavItem[] = [
  {
    id: 'meeting',
    label: 'Meeting',
    viewType: 'meeting',
    icon: 'meeting',
  },
  {
    id: 'history',
    label: 'History',
    viewType: 'history',
    icon: 'history',
  },
  {
    id: 'documents',
    label: 'Documents',
    // viewType not set - documents shown in meeting view
    icon: 'documents',
  },
  {
    id: 'settings',
    label: 'Settings',
    // viewType not set - future feature
    icon: 'settings',
  },
];

export function Sidebar() {
  const activeView = useStore((state) => state.ui.activeView);
  const setActiveView = useStore((state) => state.setActiveView);
  const isCollapsed = useStore((state) => state.ui.isSidebarCollapsed);
  const toggleSidebar = useStore((state) => state.toggleSidebar);

  return (
    <aside
      className={cn(
        'bg-bg-secondary border-r border-border-default flex flex-col transition-all duration-200',
        isCollapsed ? 'w-14' : 'w-48'
      )}
    >
      {/* Navigation items */}
      <nav className="flex-1 p-2 space-y-1">
        {navItems.map((item) => {
          const isActive = item.viewType ? activeView === item.viewType : false;
          const isDisabled = !item.viewType;
          return (
            <button
              key={item.id}
              data-testid={`nav-${item.id}`}
              onClick={() => item.viewType && setActiveView(item.viewType)}
              disabled={isDisabled}
              className={cn(
                'w-full flex items-center gap-3 px-3 py-2 rounded-terminal text-sm transition-all duration-150',
                isActive
                  ? 'bg-bg-tertiary text-text-primary'
                  : isDisabled
                  ? 'text-text-dim cursor-not-allowed opacity-50'
                  : 'text-text-muted hover:bg-bg-tertiary hover:text-text-primary'
              )}
              title={isCollapsed ? item.label : isDisabled ? `${item.label} (coming soon)` : undefined}
            >
              <Icon name={item.icon} size="md" className="flex-shrink-0" />
              {!isCollapsed && <span>{item.label}</span>}
            </button>
          );
        })}
      </nav>

      {/* Collapse toggle */}
      <div className="p-2 border-t border-border-default">
        <button
          onClick={toggleSidebar}
          className="w-full flex items-center justify-center py-2 text-text-dim hover:text-text-primary transition-colors"
          title={isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
        >
          <Icon
            name="chevron-double-left"
            size="sm"
            className={cn('transition-transform', isCollapsed && 'rotate-180')}
            strokeWidth={2}
          />
        </button>
      </div>
    </aside>
  );
}
