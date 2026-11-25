<template>
  <section class="rp-page rd-settings">
    <header class="rp-page-head"><h1 class="rp-h1">Ajustes</h1></header>

    <section class="rd-box">
      <h2>Música de este equipo</h2>
      <p class="rp-muted rp-small">El Reproductor lee las canciones de estas carpetas (y de sus subcarpetas). Las que cambien se vuelven a leer solas al abrir la app.</p>
      <ul v-if="lib.roots.length" class="rd-roots">
        <li v-for="r in lib.roots" :key="r">
          <i class="rp-i rp-i-folder" aria-hidden="true"></i>
          <span class="rp-ellipsis" :title="r">{{ r }}</span>
          <span class="rp-muted rp-small">{{ countIn(r) }} canciones</span>
          <button class="rp-mini" title="Dejar de leer esta carpeta (no se borra nada)" @click="remove(r)"><i class="rp-i rp-i-close" aria-hidden="true"></i></button>
        </li>
      </ul>
      <p v-else class="rp-muted">Ninguna carpeta: añade la tuya.</p>
      <div class="rd-actions">
        <button class="rp-btn rp-primary" @click="add"><i class="rp-i rp-i-folder-add" aria-hidden="true"></i> Añadir carpeta</button>
        <button class="rp-btn" :disabled="lib.scanning" @click="device.backend.scan()">
          <span v-if="lib.scanning" class="rp-spin"></span><i v-else class="rp-i rp-i-refresh" aria-hidden="true"></i> Volver a leer
        </button>
        <span class="rp-muted rp-small">
          <template v-if="lib.scanning && lib.progress.total">Leyendo {{ lib.progress.done }} de {{ lib.progress.total }}…</template>
          <template v-else>{{ lib.tracks.length }} canciones · {{ device.albums.length }} discos · {{ device.artists.length }} artistas</template>
        </span>
      </div>
      <p v-if="lib.error" class="rp-banner rp-banner-error">{{ lib.error }}</p>
    </section>

    <section class="rd-box"><LibrariesSettings :libraries="libraries" /></section>

    <section class="rd-box">
      <h2>Descargas</h2>
      <p class="rp-muted rp-small">Sin servidor, El Reproductor busca y baja la música a este equipo con su propio motor de descargas: todo ocurre aquí.
        <template v-if="server">Ahora mismo, conectado a tu servidor, lo que bajas va a tu nube.</template></p>
      <template v-if="es.status?.installed">
        <p class="rp-small">
          Motor {{ es.status.installed.replace(/^motor-v/, '') }}
          <span class="rp-muted"> · yt-dlp {{ es.status.ytdlp || es.status.info?.ytdlp || '—' }}<template v-if="es.status.running"> · en marcha</template></span>
        </p>
        <p class="rp-small">Se guardan en <a href="#" :title="es.status.music_dir" @click.prevent="engine.backend.openMusicDir()">{{ es.status.music_dir }}</a></p>
        <div class="rd-actions">
          <button class="rp-btn" @click="chooseDir(false)"><i class="rp-i rp-i-folder-open" aria-hidden="true"></i> Cambiar carpeta</button>
          <button class="rp-btn" :disabled="checking" title="Buscar una versión más nueva de yt-dlp (YouTube cambia a menudo)" @click="updateYtdlp">
            <span v-if="checking" class="rp-spin"></span><i v-else class="rp-i rp-i-refresh" aria-hidden="true"></i> Actualizar yt-dlp</button>
          <button v-if="engine.updatable" class="rp-btn rp-primary" :disabled="es.installing" @click="engine.install()">
            <span v-if="es.installing" class="rp-spin"></span> Instalar el motor {{ es.latest!.tag.replace(/^motor-v/, '') }}</button>
        </div>
      </template>
      <p v-else class="rp-muted rp-small">El motor aún no está instalado: se instala la primera vez que entras en «Descargar música».</p>
      <p v-if="es.error" class="rp-banner rp-banner-error">{{ es.error }}</p>
    </section>

    <section class="rd-box">
      <h2>Servidor</h2>
      <template v-if="server">
        <p>Conectado a <strong>{{ server.name || server.url }}</strong> como <strong>{{ server.username }}</strong>.</p>
        <p class="rp-muted rp-small">Ves la música de tu nube, lo que bajas va a ella y este equipo es uno más de tus dispositivos.</p>
        <div class="rd-actions"><button class="rp-btn" :disabled="busy" @click="leave">Desconectar</button></div>
      </template>
      <form v-else class="rd-form" @submit.prevent="join">
        <p class="rp-muted rp-small">Conecta un servidor de El Reproductor (el de tu Archivador) para ver toda la música de tu nube, bajar a ella y
          seguir escuchando en otros dispositivos.</p>
        <label>Dirección<input v-model.trim="form.url" class="rp-input" placeholder="https://elreproductor.ejemplo.com" required /></label>
        <label>Usuario<input v-model.trim="form.username" class="rp-input" autocomplete="username" required /></label>
        <label>Contraseña<input v-model="form.password" class="rp-input" type="password" autocomplete="current-password" required /></label>
        <label>Nombre <small class="rp-muted">(opcional)</small><input v-model.trim="form.name" class="rp-input" placeholder="El Archivador" /></label>
        <p class="rp-muted rp-tiny">La de tu cuenta de la nube. La app la usa una sola vez para crearse su propia contraseña de aplicación, que es la
          única que guarda (en el Administrador de credenciales de Windows). Puedes quitársela desde tu nube cuando quieras.</p>
        <div class="rd-actions"><button class="rp-btn rp-primary" :disabled="busy"><span v-if="busy" class="rp-spin"></span> Conectar</button></div>
      </form>
      <p v-if="error || serverError" class="rp-banner rp-banner-error">{{ error || serverError }}</p>
    </section>

    <section class="rd-box">
      <h2>El Reproductor</h2>
      <p class="rp-muted rp-small">Versión {{ version || '—' }}.</p>
      <h3 class="rd-news-h">Novedades de la 0.2.0</h3>
      <ul class="rd-news">
        <li>Bibliotecas: añade tu Navidrome (o cualquier servidor Subsonic) o tu Jellyfin y sus canciones se juntan con las de este equipo.</li>
        <li>Conecta tu servidor de El Reproductor (Ajustes › Servidor) y verás toda la música de tu nube, que suena al momento sin bajarla entera. Lo que bajas va a tu nube.</li>
        <li>Este equipo es uno más de tus dispositivos: pásale lo que suena en el móvil o en la web, o llévatelo de aquí.</li>
        <li>Guarda discos y listas de tu nube en este equipo para escucharlos sin conexión; una lista «mantenida» guarda sola lo que le añadas.</li>
      </ul>
      <h3 class="rd-news-h">Novedades de la 0.1.0</h3>
      <ul class="rd-news">
        <li>La música de tus carpetas, por artistas, discos y carpetas, con sus portadas y sus letras (de un .lrc o de LRCLIB).</li>
        <li>Con el motor de descargas: El Reproductor como en El Archivador. Busca artistas, discos y canciones aunque no los tengas, sigue a tus artistas, baja discos y canciones a este equipo y haz listas que se completan solas.</li>
        <li>Las teclas multimedia del teclado, abrir canciones desde el Explorador y soltar canciones o carpetas en la ventana.</li>
      </ul>
    </section>
  </section>
</template>

<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { LibrariesSettings, type DeviceLibrary, type LocalEngine, type RemoteLibraries } from 'reproductor-player'
import type { Connection } from './lib/server'

const props = defineProps<{
  device: DeviceLibrary
  engine: LocalEngine
  libraries: RemoteLibraries
  version: string
  /** the server connected, if any */
  server: Connection | null
  serverError: string
  /** a saved server that could not be reached: its address and user, to write the password again */
  saved?: Connection | null
  connect: (c: Connection, password: string) => Promise<void>
  disconnect: () => Promise<void>
}>()
const form = reactive({ url: props.saved?.url || '', username: props.saved?.username || '', password: '', name: props.saved?.name || '' })
const busy = ref(false)
const error = ref('')
async function join() {
  busy.value = true
  error.value = ''
  try {
    await props.connect({ url: form.url, username: form.username, name: form.name }, form.password)
    form.password = ''
  } catch (err: any) { error.value = `No se pudo conectar: ${err?.message || err}` } finally { busy.value = false }
}
async function leave() {
  if (!window.confirm('¿Desconectar el servidor? La música de tu nube deja de verse aquí; no se borra nada.')) return
  busy.value = true
  try { await props.disconnect() } finally { busy.value = false }
}
const es = props.engine.state
const checking = ref(false)
async function chooseDir(reset: boolean) {
  try {
    const dir = await props.engine.backend.chooseMusicDir(reset)
    if (dir) await props.engine.refresh()
  } catch (err: any) { es.error = err?.message || String(err) }
}
async function updateYtdlp() {
  checking.value = true
  try { await props.engine.backend.updateYtdlp(true); await props.engine.refresh() } catch (err: any) { es.error = err?.message || String(err) } finally { checking.value = false }
}
onMounted(async () => { await props.engine.refresh().catch(() => {}); if (es.status?.installed) props.engine.findLatest() })
const lib = props.device.state
const countIn = (root: string) => { const r = root.toLowerCase(); return lib.tracks.filter((t) => t.path.toLowerCase().startsWith(r)).length }
async function add() { try { await props.device.backend.addRoot() } catch (err: any) { lib.error = err?.message || String(err) } }
async function remove(root: string) {
  if (!window.confirm(`¿Dejar de leer «${root}»? Sus canciones salen de El Reproductor, pero no se borra ningún archivo.`)) return
  await props.device.backend.removeRoot(root)
}
</script>
