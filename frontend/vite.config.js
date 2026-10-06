import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    // `npm run dev` talks to a backend running locally on :3000.
    proxy: { '/api': 'http://localhost:3000' },
  },
});
