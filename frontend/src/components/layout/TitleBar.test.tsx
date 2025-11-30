import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import { TitleBar } from './TitleBar';

describe('TitleBar', () => {
  const mockElectronAPI = {
    minimize: vi.fn().mockResolvedValue(undefined),
    maximize: vi.fn().mockResolvedValue(undefined),
    close: vi.fn().mockResolvedValue(undefined),
    isMaximized: vi.fn().mockResolvedValue(false),
    onMaximizeChange: vi.fn(),
  };

  beforeEach(() => {
    vi.clearAllMocks();
    Object.defineProperty(window, 'electronAPI', {
      value: mockElectronAPI,
      writable: true,
    });
  });

  describe('macOS platform (darwin)', () => {
    it('renders traffic light buttons on the left', () => {
      render(<TitleBar platform="darwin" />);

      const closeButton = screen.getByTestId('window-close');
      const minimizeButton = screen.getByTestId('window-minimize');
      const maximizeButton = screen.getByTestId('window-maximize');

      expect(closeButton).toBeInTheDocument();
      expect(minimizeButton).toBeInTheDocument();
      expect(maximizeButton).toBeInTheDocument();
    });

    it('renders traffic light buttons with correct macOS colors', () => {
      render(<TitleBar platform="darwin" />);

      const closeButton = screen.getByTestId('window-close');
      const minimizeButton = screen.getByTestId('window-minimize');
      const maximizeButton = screen.getByTestId('window-maximize');

      // Check for traffic light styling (red, yellow, green)
      expect(closeButton).toHaveClass('bg-[#FF5F57]');
      expect(minimizeButton).toHaveClass('bg-[#FEBC2E]');
      expect(maximizeButton).toHaveClass('bg-[#28C840]');
    });

    it('renders buttons in correct order (close, minimize, maximize)', () => {
      const { container } = render(<TitleBar platform="darwin" />);

      const buttons = container.querySelectorAll('[data-testid^="window-"]');
      const testIds = Array.from(buttons).map(btn => btn.getAttribute('data-testid'));

      expect(testIds).toEqual(['window-close', 'window-minimize', 'window-maximize']);
    });

    it('renders app title in center area', () => {
      render(<TitleBar platform="darwin" />);

      expect(screen.getByText('macapy')).toBeInTheDocument();
      expect(screen.getByText('Meeting Assistant')).toBeInTheDocument();
    });
  });

  describe('Windows platform (win32)', () => {
    it('renders window controls on the right', () => {
      render(<TitleBar platform="win32" />);

      const closeButton = screen.getByTestId('window-close');
      const minimizeButton = screen.getByTestId('window-minimize');
      const maximizeButton = screen.getByTestId('window-maximize');

      expect(closeButton).toBeInTheDocument();
      expect(minimizeButton).toBeInTheDocument();
      expect(maximizeButton).toBeInTheDocument();
    });

    it('renders buttons in correct order (minimize, maximize, close)', () => {
      const { container } = render(<TitleBar platform="win32" />);

      const buttons = container.querySelectorAll('[data-testid^="window-"]');
      const testIds = Array.from(buttons).map(btn => btn.getAttribute('data-testid'));

      expect(testIds).toEqual(['window-minimize', 'window-maximize', 'window-close']);
    });

    it('renders app title on the left', () => {
      render(<TitleBar platform="win32" />);

      expect(screen.getByText('macapy')).toBeInTheDocument();
      expect(screen.getByText('Meeting Assistant')).toBeInTheDocument();
    });
  });

  describe('Linux platform', () => {
    it('renders window controls same as Windows', () => {
      render(<TitleBar platform="linux" />);

      const closeButton = screen.getByTestId('window-close');
      const minimizeButton = screen.getByTestId('window-minimize');
      const maximizeButton = screen.getByTestId('window-maximize');

      expect(closeButton).toBeInTheDocument();
      expect(minimizeButton).toBeInTheDocument();
      expect(maximizeButton).toBeInTheDocument();
    });
  });

  describe('Window control interactions', () => {
    it('calls minimize when minimize button is clicked', async () => {
      render(<TitleBar platform="darwin" />);

      const minimizeButton = screen.getByTestId('window-minimize');
      fireEvent.click(minimizeButton);

      expect(mockElectronAPI.minimize).toHaveBeenCalledTimes(1);
    });

    it('calls maximize when maximize button is clicked', async () => {
      render(<TitleBar platform="darwin" />);

      const maximizeButton = screen.getByTestId('window-maximize');
      fireEvent.click(maximizeButton);

      expect(mockElectronAPI.maximize).toHaveBeenCalledTimes(1);
    });

    it('calls close when close button is clicked', async () => {
      render(<TitleBar platform="darwin" />);

      const closeButton = screen.getByTestId('window-close');
      fireEvent.click(closeButton);

      expect(mockElectronAPI.close).toHaveBeenCalledTimes(1);
    });

    it('calls minimize when minimize button is clicked (Windows)', async () => {
      render(<TitleBar platform="win32" />);

      const minimizeButton = screen.getByTestId('window-minimize');
      fireEvent.click(minimizeButton);

      expect(mockElectronAPI.minimize).toHaveBeenCalledTimes(1);
    });

    it('calls maximize when maximize button is clicked (Windows)', async () => {
      render(<TitleBar platform="win32" />);

      const maximizeButton = screen.getByTestId('window-maximize');
      fireEvent.click(maximizeButton);

      expect(mockElectronAPI.maximize).toHaveBeenCalledTimes(1);
    });

    it('calls close when close button is clicked (Windows)', async () => {
      render(<TitleBar platform="win32" />);

      const closeButton = screen.getByTestId('window-close');
      fireEvent.click(closeButton);

      expect(mockElectronAPI.close).toHaveBeenCalledTimes(1);
    });
  });

  describe('Accessibility', () => {
    it('has accessible labels for all buttons', () => {
      render(<TitleBar platform="darwin" />);

      expect(screen.getByRole('button', { name: 'Close' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Minimize' })).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /maximize|restore/i })).toBeInTheDocument();
    });

    it('updates maximize button label when window is maximized', async () => {
      mockElectronAPI.isMaximized.mockResolvedValue(true);

      render(<TitleBar platform="darwin" />);

      // Wait for the effect to run
      await vi.waitFor(() => {
        expect(screen.getByRole('button', { name: 'Restore' })).toBeInTheDocument();
      });
    });
  });

  describe('Null platform handling', () => {
    it('renders Windows-style controls when platform is null', () => {
      render(<TitleBar platform={null} />);

      const closeButton = screen.getByTestId('window-close');
      const minimizeButton = screen.getByTestId('window-minimize');
      const maximizeButton = screen.getByTestId('window-maximize');

      expect(closeButton).toBeInTheDocument();
      expect(minimizeButton).toBeInTheDocument();
      expect(maximizeButton).toBeInTheDocument();

      // Should render Windows-style (not traffic lights)
      expect(closeButton).not.toHaveClass('rounded-full');
    });
  });
});
