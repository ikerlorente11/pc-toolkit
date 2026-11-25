<template>
  <ReproductorShell :key="local ? 'local' : 'device'" :api="local?.api" :sl="local?.sl" :files="files" :device="device" :engine="engine"
                    :view="view" :navigate="navigate" music-root="Música" cloud-name="Windows" :me="local ? undefined : me"
                    :where="local ? 'este equipo' : undefined" :device-also="local ? engine.state.status?.music_dir : undefined">
    <template #settings><SettingsView :device="device" :engine="engine" :version="version" /></template>
  </ReproductorShell>
  <div v-if="dropping" class="rd-drop">Suelta canciones para escucharlas, o carpetas para añadirlas a tu música</div>
</template>

<script setup lang="ts">
import { onBeforeUnmount, onMounted, reactive, ref, shallowRef, watch } from 'vue'
import { getVersion } from '@tauri-apps/api/app'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { getCurrentWebview } from '@tauri-apps/api/webview'
import {
  Api, DeviceLibrary, LocalEngine, ReproductorShell, Soundlift, deviceId, isAudioName, play, queryFromView, viewFromQuery, type Files, type Me, type View
} from 'reproductor-player'
import 'reproductor-player/ui.css'
import { openUrl } from '@tauri-apps/plugin-opener'
import { addRoot, desktopDevice, mediaUrl, openFile } from './lib/device'
import { desktopEngine } from './lib/engine'
import SettingsView from './SettingsView.vue'

/**
 * El Reproductor for Windows: the shared app (reproductor-player) over the music of this PC (the Rust side
 * indexes the chosen folders and serves the songs). With the download engine installed, it starts with the app and
 * the app is El Reproductor as on the server (its service runs in the engine, on this PC: search the catalogue,
 * follow artists, download albums and songs, playlists…), the engine's music folder standing for the cloud's
 * /Música. Where the app is lives in the window's hash (#v=album&…), so the mouse's back and forward buttons work.
 */
const device = new DeviceLibrary(desktopDevice())
/** soundlift and the El Reproductor service on this PC: the app downloads music by itself (no server does the work) */
const engine = new LocalEngine(desktopEngine())
/** El Reproductor's service and soundlift of the engine, once it runs (then the app shows El Reproductor's pages) */
const local = shallowRef<{ api: Api; sl: Soundlift } | null>(null)
async function startLocal() {
  if (local.value || engine.state.starting) return
  try {
    const r = await engine.start()
    const api = new Api(`http://127.0.0.1:${r.rp_port}`, Api.bearer(() => r.token))
    const sl = new Soundlift(`http://127.0.0.1:${r.port}`, () => '')
    api.fetch = sl.fetch = engine.backend.fetch
    local.value = { api, sl }
  } catch (_) { /* the error shows in Descargar música and Ajustes */ }
}
// installed now (from «Descargar música»): it starts at once
watch(() => engine.state.status?.installed, (installed) => { if (installed) startLocal() })
// started again on other ports (the music folder changed in Ajustes, a newer engine): the pages follow it
watch(() => engine.state.status?.running?.rp_port, (port, before) => {
  if (before && port !== before) { local.value = null; if (engine.state.status?.installed) startLocal() }
})
// What it downloads goes to a folder that must be in the library (by default inside Música, which already is):
// once the engine runs (the folder exists), it is added if it is outside the library's folders.
watch(() => engine.state.status?.running && engine.state.status.music_dir, (dir) => { if (dir) addRoot(dir).catch(() => {}) })
const version = ref('')
/** This PC among the user's devices (once connected to a server): «Escritorio · NOMBRE-DEL-PC». */
const me = reactive<Me>({ id: deviceId(), name: 'Escritorio', kind: 'desktop' })
invoke<string>('device_name').then((n) => { if (n) me.name = `Escritorio · ${n}` }).catch(() => {})

/** The Rust side says "404" for what is not there: the pages expect `status: 404`. */
const failed = (err: unknown) => Object.assign(new Error(String(err)), { status: String(err) === '404' ? 404 : undefined })
/** The songs: this PC's by their id in the index; El Reproductor's by their path in the engine's music folder. */
const files: Files = {
  async list(dir) {
    try { return await invoke('music_list', { dir }) } catch (err) { throw failed(err) }
  },
  async remove(path) {
    try { await invoke('music_remove', { path }) } catch (err) { throw failed(err) }
  },
  async play(song) {
    if (song.device) return { url: device.backend.fileUrl(song.device) }
    return { url: mediaUrl('m' + song.path.split('/').map(encodeURIComponent).join('/')) }
  }
}

const readHash = (): View => viewFromQuery(Object.fromEntries(new URLSearchParams(location.hash.replace(/^#/, ''))))
const view = ref<View>(readHash())
function navigate(next: View, replace = false) {
  const hash = '#' + new URLSearchParams(queryFromView(next)).toString()
  if (replace) history.replaceState(null, '', hash)
  else if (hash !== location.hash) history.pushState(null, '', hash)
  view.value = next
}
const onPop = () => { view.value = readHash() }

/** Links meant for a new tab (a song on YouTube, a source's page) open in the system's browser. */
function onLink(e: MouseEvent) {
  const a = (e.target as HTMLElement)?.closest?.('a[target="_blank"]') as HTMLAnchorElement | null
  if (!a || !/^https?:/.test(a.href)) return
  e.preventDefault()
  openUrl(a.href).catch(() => {})
}

/** A song opened from the Explorer: on its own, or with the rest of its album when it is in the library. */
async function playPath(path: string) {
  try {
    const track = await openFile(path)
    const album = device.album(device.song(track).albumKey || '')
    const songs = album?.tracks.some((t) => t.id === track.id) ? device.songs(album.tracks) : [device.song(track)]
    play(songs, songs.find((s) => s.device === track.id) || songs[0], false)
  } catch (err: any) {
    console.error(err)
  }
}

// ---- dropping songs (to play) or folders (to add) on the window ----
const dropping = ref(false)
let unlisten: (() => void)[] = []
onMounted(async () => {
  window.addEventListener('popstate', onPop)
  document.addEventListener('click', onLink, true)
  version.value = await getVersion().catch(() => '')
  await device.start().catch((err) => { device.state.error = String(err) })
  if ((await engine.refresh().catch(() => null))?.installed) startLocal()
  const launched = await invoke<string | null>('launch_path')
  if (launched) playPath(launched)
  unlisten.push(await listen<string>('open-file', (e) => playPath(e.payload)))
  unlisten.push(await getCurrentWebview().onDragDropEvent(async (e) => {
    const p = e.payload
    if (p.type === 'enter' || p.type === 'over') { dropping.value = true; return }
    dropping.value = false
    if (p.type !== 'drop') return
    const songs = p.paths.filter((x) => isAudioName(x))
    for (const dir of p.paths.filter((x) => !isAudioName(x) && !/\.[a-z0-9]{2,4}$/i.test(x))) await addRoot(dir).catch(() => {})
    if (songs.length) playPath(songs[0])
  }))
})
onBeforeUnmount(() => {
  window.removeEventListener('popstate', onPop)
  document.removeEventListener('click', onLink, true)
  unlisten.forEach((u) => u())
})
</script>
