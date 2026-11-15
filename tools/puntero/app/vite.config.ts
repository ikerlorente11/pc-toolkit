import { defineConfig } from 'vite'

// Tauri serves the built files itself; in development it opens the dev server on a fixed port.
export default defineConfig({
  clearScreen: false,
  server: { port: 1430, strictPort: true },
  build: { target: 'chrome105', minify: 'esbuild', sourcemap: false }
})
