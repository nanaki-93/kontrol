import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { App } from './app/App';
import './styles.css';

// Internet connectivity must never pause calls to our local server.
const client = new QueryClient({ defaultOptions: {
  queries: { refetchOnWindowFocus: true, networkMode: 'always' }, mutations: { retry: false, networkMode: 'always' },
} });
createRoot(document.getElementById('root')!).render(<StrictMode><QueryClientProvider client={client}><App /></QueryClientProvider></StrictMode>);
