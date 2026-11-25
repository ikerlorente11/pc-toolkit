/** The download engine as the Rust side runs it (src-tauri/src/engine.rs): soundlift for Windows, downloaded apart
 *  the first time, started on a free loopback port. The page talks to it through Tauri's HTTP (from Rust: no CORS). */
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { open } from '@tauri-apps/plugin-dialog'
import { fetch as tauriFetch } from '@tauri-apps/plugin-http'
import type { EngineBackend, EngineRunning, EngineStatus } from 'reproductor-player'

export function desktopEngine(): EngineBackend {
  return {
    status: () => invoke<EngineStatus>('motor_status'),
    latest: () => invoke<{ tag: string; size: number }>('motor_latest'),
    install: () => invoke<string>('motor_install'),
    updateYtdlp: (force = false) => invoke<string | null>('motor_update_ytdlp', { force }),
    start: () => invoke<EngineRunning>('motor_start'),
    async chooseMusicDir(reset = false) {
      if (reset) return invoke<string>('motor_set_music_dir', { path: null })
      const dir = await open({ directory: true, multiple: false, title: 'Elige dónde guardar la música que descargues' })
      if (!dir || Array.isArray(dir)) return null
      return invoke<string>('motor_set_music_dir', { path: dir })
    },
    openMusicDir: () => invoke('motor_open_music_dir'),
    onProgress(fn) {
      let off: (() => void) | null = null
      listen<{ done: number; total: number }>('motor-progress', (e) => fn(e.payload)).then((u) => { off = u })
      return () => off?.()
    },
    fetch: (input, init) => tauriFetch(input, init)
  }
}
