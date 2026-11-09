import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// Tauri serves the built files itself; in development it opens the dev server on a fixed port.
const host = process.env.TAURI_DEV_HOST
export default defineConfig({
  plugins: [vue()],
  clearScreen: false,
  server: { port: 1420, strictPort: true, host: host || false, hmr: host ? { protocol: 'ws', host, port: 1421 } : undefined },
  build: { target: 'chrome105', minify: 'esbuild', sourcemap: false }
})
