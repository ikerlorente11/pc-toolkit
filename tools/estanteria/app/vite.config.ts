import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'
import { defineConfig, searchForWorkspaceRoot } from 'vite'
import vue from '@vitejs/plugin-vue'

// Tauri serves the built files itself; in development it opens the dev server on a fixed port.
const host = process.env.TAURI_DEV_HOST
// To try a viewer that is not published yet: ESTANTERIA_VIEWER=<the estanteria repo's viewer/ folder> pnpm tauri dev
// (its source, watched and hot-reloaded, instead of the commit package.json pins).
const local = process.env.ESTANTERIA_VIEWER ? resolve(process.env.ESTANTERIA_VIEWER, 'src') : null
const here = fileURLToPath(new URL('.', import.meta.url))
export default defineConfig({
  plugins: [vue()],
  clearScreen: false,
  resolve: local ? {
    alias: [{ find: 'estanteria-viewer/ui.css', replacement: `${local}/lib/ui.css` }, { find: 'estanteria-viewer', replacement: `${local}/index.ts` }],
    // the viewer's own imports come from this project's node_modules
    dedupe: ['vue', 'pdfjs-dist']
  } : undefined,
  server: {
    port: 1420, strictPort: true, host: host || false, hmr: host ? { protocol: 'ws', host, port: 1421 } : undefined,
    fs: local ? { allow: [searchForWorkspaceRoot(here), local] } : undefined
  },
  build: { target: 'chrome105', minify: 'esbuild', sourcemap: false }
})
