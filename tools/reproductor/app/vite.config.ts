import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'
import { defineConfig, searchForWorkspaceRoot } from 'vite'
import vue from '@vitejs/plugin-vue'

// Tauri serves the built files itself; in development it opens the dev server on a fixed port.
const host = process.env.TAURI_DEV_HOST
// To try a player that is not published yet: REPRODUCTOR_PLAYER=<the reproductor repo's player/ folder> pnpm tauri dev
// (its source, watched and hot-reloaded, instead of the commit package.json pins).
const local = process.env.REPRODUCTOR_PLAYER ? resolve(process.env.REPRODUCTOR_PLAYER, 'src') : null
const here = fileURLToPath(new URL('.', import.meta.url))
export default defineConfig({
  plugins: [vue()],
  clearScreen: false,
  resolve: {
    alias: local ? [{ find: 'reproductor-player/ui.css', replacement: `${local}/lib/ui.css` }, { find: 'reproductor-player', replacement: `${local}/index.ts` }] : [],
    // the player's own imports come from this project's node_modules
    dedupe: ['vue']
  },
  server: {
    port: 1430, strictPort: true, host: host || false, hmr: host ? { protocol: 'ws', host, port: 1431 } : undefined,
    fs: { allow: [searchForWorkspaceRoot(here), ...(local ? [local] : []), resolve(here, '../../../../reproductor/player')] }
  },
  build: { target: 'chrome105', minify: 'esbuild', sourcemap: false }
})
