// @ts-check
import { defineConfig } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';
import react from '@astrojs/react';

const backend = process.env.SSBNK_DEV_API_URL || 'http://127.0.0.1:8080';

// https://astro.build/config
export default defineConfig({
  vite: {
    plugins: [tailwindcss()],
    server: {
      proxy: {
        '/api': backend,
        '/health': backend,
        '/hybrid': backend,
        '/latest': backend,
        '/stateless': backend,
        '/upload': backend,
        '^/.*\\.(gif|jpe?g|png|webp)$': backend,
      },
    },
  },

  integrations: [react()]
});
