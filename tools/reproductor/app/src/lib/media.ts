/**
 * What plays, outside the page (src-tauri/src/window.rs): the tray's icon and menu, and the buttons of the window's
 * preview in the taskbar. This tells the Rust side what plays (or what plays on the device this one controls) and does
 * what those buttons ask, as the player's own would. And «Seguir sonando al cerrar» (Ajustes): closing the window
 * leaves the app in the tray, playing.
 */
import { ref, watch, watchEffect } from 'vue'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { connect, control, nowPlaying, player, remote } from 'reproductor-player'

const BACKGROUND = 'reproductor.background'
/** closing the window leaves the app in the tray, playing (Ajustes; off by default) */
export const background = ref((() => { try { return localStorage.getItem(BACKGROUND) === '1' } catch (_) { return false } })())

let started = false
export function startMedia() {
  if (started) return
  started = true
  watch(background, (on) => {
    try { localStorage.setItem(BACKGROUND, on ? '1' : '0') } catch (_) {}
    invoke('set_background', { on }).catch(() => {})
  }, { immediate: true })

  // what plays: here, or on the device this one controls
  let last = ''
  watchEffect(() => {
    const far = !!connect.controlling
    const r = remote.value
    const song = far ? r?.song : nowPlaying.value
    const state = { title: song?.title || '', artist: song?.artist || '', playing: far ? !!r?.playing : player.playing, loaded: !!song }
    const key = JSON.stringify(state)
    if (key === last) return
    last = key
    invoke('media_state', state).catch(() => {})
  })

  listen<string>('media', (e) => {
    if (e.payload === 'toggle') control.toggle()
    else if (e.payload === 'next') control.next()
    else if (e.payload === 'prev') control.prev()
  }).catch(() => {})
}
