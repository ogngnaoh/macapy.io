/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        // Backgrounds
        'bg-primary': 'var(--bg-primary)',
        'bg-secondary': 'var(--bg-secondary)',
        'bg-tertiary': 'var(--bg-tertiary)',

        // Text colors
        'text-primary': 'var(--text-primary)',
        'text-secondary': 'var(--text-secondary)',
        'text-muted': 'var(--text-muted)',
        'text-dim': 'var(--text-dim)',

        // Accents
        'accent-success': 'var(--accent-success)',
        'accent-warning': 'var(--accent-warning)',
        'accent-error': 'var(--accent-error)',
        'accent-cyan': 'var(--accent-cyan)',

        // Borders
        'border-default': 'var(--border-default)',
        'border-focus': 'var(--border-focus)',

        // Terminal-inspired palette
        terminal: {
          black: '#0d1117',
          darkGray: '#161b22',
          gray: '#21262d',
          lightGray: '#30363d',
          blue: '#58a6ff',
          lightBlue: '#79c0ff',
          green: '#3fb950',
          yellow: '#d29922',
          red: '#f85149',
          cyan: '#39c5cf',
          muted: '#8b949e',
          dim: '#484f58',
        },
      },
      fontFamily: {
        mono: ['JetBrains Mono', 'Fira Code', 'Monaco', 'Consolas', 'monospace'],
        sans: ['JetBrains Mono', 'system-ui', 'sans-serif'],
      },
      fontSize: {
        'xs': ['0.75rem', { lineHeight: '1.25rem' }],
        'sm': ['0.875rem', { lineHeight: '1.5rem' }],
        'base': ['1rem', { lineHeight: '1.75rem' }],
        'lg': ['1.125rem', { lineHeight: '1.875rem' }],
        'xl': ['1.25rem', { lineHeight: '2rem' }],
      },
      animation: {
        'pulse-recording': 'pulse-recording 2s cubic-bezier(0.4, 0, 0.6, 1) infinite',
        'slide-up': 'slide-up 0.3s ease-out',
        'slide-down': 'slide-down 0.3s ease-out',
        'fade-in': 'fade-in 0.2s ease-out',
        'fade-out': 'fade-out 0.2s ease-out',
        'blink': 'blink 1s step-end infinite',
        'typing': 'typing 0.5s ease-out',
      },
      keyframes: {
        'pulse-recording': {
          '0%, 100%': {
            opacity: '1',
            transform: 'scale(1)',
          },
          '50%': {
            opacity: '0.5',
            transform: 'scale(1.05)',
          },
        },
        'slide-up': {
          '0%': {
            opacity: '0',
            transform: 'translateY(10px)',
          },
          '100%': {
            opacity: '1',
            transform: 'translateY(0)',
          },
        },
        'slide-down': {
          '0%': {
            opacity: '0',
            transform: 'translateY(-10px)',
          },
          '100%': {
            opacity: '1',
            transform: 'translateY(0)',
          },
        },
        'fade-in': {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' },
        },
        'fade-out': {
          '0%': { opacity: '1' },
          '100%': { opacity: '0' },
        },
        'blink': {
          '0%, 100%': { opacity: '1' },
          '50%': { opacity: '0' },
        },
        'typing': {
          '0%': {
            opacity: '0',
            transform: 'translateX(-5px)',
          },
          '100%': {
            opacity: '1',
            transform: 'translateX(0)',
          },
        },
      },
      boxShadow: {
        'terminal': '0 0 10px rgba(88, 166, 255, 0.1)',
        'terminal-lg': '0 0 20px rgba(88, 166, 255, 0.15)',
        'glow-blue': '0 0 15px rgba(88, 166, 255, 0.3)',
        'glow-green': '0 0 15px rgba(63, 185, 80, 0.3)',
        'glow-red': '0 0 15px rgba(248, 81, 73, 0.3)',
      },
      borderRadius: {
        'terminal': '4px',
      },
      spacing: {
        '18': '4.5rem',
        '88': '22rem',
        '120': '30rem',
      },
    },
  },
  plugins: [],
};
