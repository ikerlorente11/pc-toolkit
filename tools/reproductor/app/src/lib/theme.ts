/** The app's theme: the system's (light or dark, as Windows is set) or one chosen in Ajustes. Kept in this page's
 * storage; the colours are desktop.css's (`data-theme` on <html> when one is chosen), and the window is told too, so
 * its title bar goes with it. */
import { ref, watch } from 'vue'
import { getCurrentWindow } from '@tauri-apps/api/window'

export type Theme = 'system' | 'light' | 'dark'
const KEY = 'reproductor.theme'

function read(): Theme {
  try { const v = localStorage.getItem(KEY); return v === 'light' || v === 'dark' ? v : 'system' } catch (_) { return 'system' }
}
export const theme = ref<Theme>(read())

function apply() {
  if (theme.value === 'system') delete document.documentElement.dataset.theme
  else document.documentElement.dataset.theme = theme.value
  // the title bar: Windows' own (null: as the system)
  getCurrentWindow().setTheme(theme.value === 'system' ? null : theme.value).catch(() => {})
}
watch(theme, (t) => {
  try { if (t === 'system') localStorage.removeItem(KEY); else localStorage.setItem(KEY, t) } catch (_) {}
  apply()
})
apply()
