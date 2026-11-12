<template>
  <div class="es" :class="{ 'es-reading': view.v === 'read' || view.v === 'chapter' }">
    <template v-if="view.v === 'read' && store">
      <ReaderView :key="`read${view.id}${view.as || ''}`" :id="view.id" :start-page="view.page" :as="view.as" />
    </template>
    <template v-else-if="view.v === 'chapter' && store">
      <ChapterReader :key="`ch${view.chapter}`" :catalog="view.catalog" :chapter="view.chapter" :title="view.title" />
    </template>
    <template v-else>
      <aside class="es-side" :aria-label="t('Tu estantería')">
        <div class="es-brand">
          <span class="es-brand-mark" aria-hidden="true"><i class="es-i es-i-book" aria-hidden="true"></i></span>
          <strong>La Estantería</strong>
        </div>
        <nav class="es-nav">
          <a href="#" :class="{ on: view.v === 'home' }" @click.prevent="go({ v: 'home' })"><span class="es-ni"><i class="es-i es-i-home" aria-hidden="true"></i></span> {{ t('Inicio') }}</a>
          <a href="#" :class="{ on: view.v === 'library' }" @click.prevent="go({ v: 'library' })"><span class="es-ni"><i class="es-i es-i-grid" aria-hidden="true"></i></span> {{ t('Estantería') }}</a>
          <a href="#" :class="{ on: view.v === 'catalogs' || view.v === 'catalog' }" @click.prevent="go({ v: 'catalogs' })"><span class="es-ni"><i class="es-i es-i-cloud" aria-hidden="true"></i></span> {{ t('Catálogos') }}</a>
          <a href="#" :class="{ on: view.v === 'sources' }" @click.prevent="go({ v: 'sources' })"><span class="es-ni"><i class="es-i es-i-server" aria-hidden="true"></i></span> {{ t('Bibliotecas') }}</a>
        </nav>
        <div class="es-lib">
          <div class="es-libh">{{ t('Series') }} <small class="es-muted">{{ state.series.length }}</small></div>
          <p v-if="!state.loaded" class="es-muted es-small es-libnote"><span class="es-spin"></span> {{ t('Cargando…') }}</p>
          <ul v-else class="es-serieslist">
            <li v-for="s in state.series" :key="s.series">
              <a href="#" :class="{ on: view.v === 'series' && view.name === s.series }" @click.prevent="go({ v: 'series', name: s.series })">
                <Cover :id="s.cover_item" :has="s.cover" class="es-thumb" />
                <span class="es-sname"><span class="es-ellipsis">{{ s.series }}</span><small class="es-muted">{{ plural(s.items, '{n} número', '{n} números') }}</small></span>
              </a>
            </li>
          </ul>
        </div>
        <a href="#" class="es-back" :class="{ on: view.v === 'setup' }" @click.prevent="go({ v: 'setup' } as any)"><i class="es-i es-i-settings" aria-hidden="true"></i> {{ t('Ajustes') }}</a>
      </aside>

      <main ref="mainEl" class="es-main">
        <div v-if="!isRoot" class="es-topbar">
          <button class="es-topbtn" type="button" :aria-label="t('Volver')" :title="t('Volver')" @click="back()"><i class="es-i es-i-back" aria-hidden="true"></i></button>
        </div>
        <p v-if="offline && !offline.state.online" class="es-offline-banner">
          <i class="es-i es-i-cloud" aria-hidden="true"></i>
          <span>{{ t('Sin conexión con {server}: puedes leer lo descargado. Lo que leas se apunta y se envía al volver.', { server: serverName }) }}</span>
          <span class="es-grow"></span>
          <button class="es-btn es-small" @click="refresh()">{{ t('Reintentar') }}</button>
        </p>
        <p v-if="state.error && view.v !== 'sources'" class="es-banner es-banner-error">{{ state.error }} <button class="es-btn es-small" @click="go({ v: 'sources' })">{{ t('Bibliotecas') }}</button></p>
        <template v-if="store">
          <SettingsView v-if="view.v === 'setup'" />
          <HomeView v-else-if="view.v === 'home'" />
          <LibraryView v-else-if="view.v === 'library'" :q="view.q || ''" :kind="view.kind" :sort="view.sort" :folder="view.folder" :source="view.source" />
          <SeriesView v-else-if="view.v === 'series'" :key="`s${view.name}`" :name="view.name" />
          <ItemView v-else-if="view.v === 'item'" :key="`i${view.id}`" :id="view.id" />
          <SourcesView v-else-if="view.v === 'sources'" :add="view.add" />
          <ExtensionsView v-else-if="view.v === 'extensions'" :key="`x${view.library}`" :library="view.library" />
          <CatalogsView v-else-if="view.v === 'catalogs'" />
          <DownloadsView v-else-if="view.v === 'downloads'" />
          <CatalogView v-else-if="view.v === 'catalog'" :key="`c${view.kind}`" :kind="view.kind" :path="view.path" :q="view.q" />
        </template>
      </main>
    </template>
    <div v-if="toast.text" :class="['es-toast', { 'es-toast-error': toast.error }]" role="status">{{ toast.text }}</div>
    <LockScreen v-if="lock.locked.value && native?.lock" :lock="native.lock" @unlocked="lock.unlocked()" />
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, provide, reactive, ref, shallowReactive, shallowRef, watch } from 'vue'
import { getVersion } from '@tauri-apps/api/app'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { getCurrentWebview } from '@tauri-apps/api/webview'
import { open } from '@tauri-apps/plugin-dialog'
import { Api, CatalogRegistry, ExtensionsView, withDeviceLibraries, LockScreen, appSettings, useAppLock, CatalogView, CatalogsView, ChapterReader, Cover, DownloadsView, HomeView, LocalShelf, Offline, ImageCache, ItemView, LibraryView, ReaderView, SeriesView, SettingsView, SourcesView, STORE,
         createState, nameFromUrl, plural, queryFromView, t, useScrollMemory, viewFromQuery, type Item, type Theme, type Library, type LibrariesBackend, type Store, type View } from 'estanteria-viewer'
import { forgetToken, loadConnection, loadToken, saveConnection, saveToken, type Connection } from './lib/settings'
import { accountKey, desktopBackend } from './lib/offline'
import { desktopShelf } from './lib/shelf'
import { desktopNet } from './lib/net'
import { desktopNative } from './lib/native'

/**
 * The desktop shell of La Estantería: the same library and readers as the web. First a reader of this
 * PC's files (its shelf), with no account; libraries are connected in «Bibliotecas» (for now a server of
 * its own, with an app token over HTTP basic: its library, outside libraries and catalogs join the
 * shelf). The page shown lives in the URL's hash (#v=series&name=…), so back and forward work.
 */
const version = ref('')
const connection = reactive<Connection>({ url: '', username: '', name: '' })
/** a server of its own is connected (without one the app reads this PC alone) */
const connected = ref(false)
/** why the server does not connect, shown next to it in «Bibliotecas» */
const serverError = ref('')
const serverName = computed(() => connection.name || (connection.url ? nameFromUrl(connection.url) : t('el servidor')))
const state = createState()
const toast = reactive({ text: '', error: false })
const mainEl = ref<HTMLElement>()
let toastTimer: any = null
const token = ref('')

// ---- the theme: the system's, or one chosen in Ajustes (kept in this PC) ----
const THEME_KEY = 'estanteria.theme'
const theme = ref<Theme>((() => { try { return (localStorage.getItem(THEME_KEY) as Theme) || 'system' } catch (_) { return 'system' } })())
function applyTheme() {
  if (theme.value === 'system') delete document.documentElement.dataset.theme
  else document.documentElement.dataset.theme = theme.value
}
function setTheme(t: Theme) {
  theme.value = t
  try { localStorage.setItem(THEME_KEY, t) } catch (_) {}
  applyTheme()
}
applyTheme()

// ---- navigation in the hash ----
const hash = ref(window.location.hash)
window.addEventListener('hashchange', () => { hash.value = window.location.hash })
// each page keeps its scroll: back to a list, it is where it was
const scroll = useScrollMemory(mainEl, hash)
const view = computed<View | { v: 'setup' }>(() => {
  const params = Object.fromEntries(new URLSearchParams(hash.value.replace(/^#/, '')))
  return params.v === 'setup' ? { v: 'setup' } : viewFromQuery(params)
})
function go(next: View | { v: 'setup' }, replace = false) {
  const query = next.v === 'setup' ? 'v=setup' : new URLSearchParams(queryFromView(next as View)).toString()
  if (`#${query}` !== hash.value) scroll.forward()
  if (replace) window.history.replaceState(null, '', `#${query}`)
  else window.location.hash = query
  hash.value = `#${query}`
}
/** the main pages (the tabs): no «back» there */
const isRoot = computed(() => {
  const v = view.value as any
  if (v.v === 'library') return !v.folder && !v.source && !v.q
  return ['home', 'catalogs', 'sources'].includes(v.v)
})
function back() {
  if (window.history.length > 1) window.history.back()
  else go({ v: 'home' })
}

function notify(text: string, error = false) {
  toast.text = text
  toast.error = error
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toast.text = '' }, error ? 7000 : 3500)
}

// ---- the service ----
const api = new Api('', () => '')
let current: Api = api
const store = shallowRef<Store | null>(null)
// ---- reading without connection: one keeper per account (its downloads go on across reconnections) ----
const keepers = new Map<string, Offline>()
const offline = shallowRef<Offline | null>(null)
function keeperFor(): Offline {
  const account = accountKey(connection.username, connection.url)
  let keeper = keepers.get(account)
  if (!keeper) {
    keeper = new Offline(desktopBackend(account, () => connection.url, () => Api.basic(connection.username, token.value), () => serverName.value))
    keepers.set(account, keeper)
  }
  return keeper
}

// ---- the folders and files of this PC: one shelf for the computer, whatever the account ----
const shelf = new LocalShelf(desktopShelf(() => connection.url, () => Api.basic(connection.username, token.value)))

// ---- the catalogs this app reads by itself, and its network (no CORS) ----
const catalogs = new CatalogRegistry()
/** the device's lock (Windows Hello), when it has one */
const native = desktopNative()
const lock = useAppLock(() => native)
const net = desktopNet()

/** The store with a server (its API, with the app token) or without (this PC's shelf answers). */
function makeStore(server: boolean): Store {
  current = server ? new Api(connection.url, () => Api.basic(connection.username, token.value)) : Api.onDevice()
  let keeper = server ? keeperFor() : keepers.get('')
  if (!keeper) { keeper = new Offline(desktopBackend('local', () => '', () => '')); keepers.set('', keeper) }
  keeper.attach(current)
  keeper.shelf = shelf
  offline.value = keeper
  const covers = new ImageCache(current, 400)
  const pages = new ImageCache(current, 24)
  const s: Store = { api: current, covers, pages, readingRoot: 'Lectura', state, refresh, go: go as any, back, notify, read, offline: keeper, shelf,
    libraries: allLibraries, serverName: server ? serverName.value : undefined,
    appearance: { theme, setTheme }, version: version.value && version.value !== 'dev' ? version.value : undefined, catalogs, net, platform: 'desktop', native,
    downloadsFolder: () => invoke<string>('net_downloads_dir'), setDownloadsFolder }
  return s
}
/** Another folder for the downloads (or back to the usual places): Rust moves the copies kept offline there. */
async function setDownloadsFolder(reset: boolean): Promise<string | null> {
  const path = reset ? '' : await open({ directory: true, title: t('Carpeta de las descargas') })
  if (path === null || Array.isArray(path)) return null
  const now = await invoke<string>('downloads_set_dir', { path })
  for (const keeper of keepers.values()) await keeper.load()
  // what came from the catalogs moved with it (same ids): the shelf lists it at its new place
  await shelf.load()
  await refresh()
  return now
}
/** Puts a store in place: the pages see `state.connected` go up again and load with it. */
async function use(server: boolean) {
  state.connected = false
  const s = makeStore(server)
  await offline.value?.load()
  provideStore(s)
  store.value = s
  connected.value = server
  state.server = server
  state.connected = true
  await refresh()
}
function read(item: Item) {
  const page = item.kind !== 'book' && item.progress && !item.progress.finished && item.progress.page ? item.progress.page : undefined
  go({ v: 'read', id: item.id, page })
}
async function refresh() {
  try {
    const [status, series] = await Promise.all([current.library(), current.series()])
    state.status = status
    state.series = series
    state.loaded = true
    state.error = ''
  } catch (err: any) {
    // only a server can fail to answer: this device's own shelf has nothing to go wrong with
    if (state.server) state.error = t('No se pudo cargar tu estantería: {error}', { error: err?.message || String(err) })
  }
}
/** With a server if one is set up and it lets us in (when it does not answer, it is read offline from what
 * was kept); else this PC alone. True when the server is in use. */
async function connect(): Promise<boolean> {
  state.error = ''
  serverError.value = ''
  if (!connection.url || !connection.username || !token.value) { await use(false); listLibraries(); return false }
  try {
    await new Api(connection.url, () => Api.basic(connection.username, token.value)).ensureConnected()
  } catch (err: any) {
    if (!err?.offline) {
      serverError.value = err?.status === 401 ? t('No reconoce ese usuario o esa contraseña de aplicación.') : t('No se pudo conectar: {error}', { error: err?.message || String(err) })
      await use(false)
      listLibraries()
      return false
    }
  }
  await use(true)
  listLibraries()
  return true
}

// ---- «Bibliotecas»: what this app connects by itself (for now, one server of its own) ----
const libraryList = ref<Library[]>([])
function listLibraries() {
  libraryList.value = connection.url && connection.username
    ? [{ id: 'server', type: 'server', name: serverName.value, url: connection.url, username: connection.username, hasSecret: !!token.value, error: serverError.value || undefined }]
    : []
}
const libraries: LibrariesBackend = {
  types: ['server'],
  list: libraryList,
  async save(input) {
    if (input.type !== 'server') throw new Error(t('Este tipo de biblioteca aún no se puede conectar desde aquí.'))
    if (!input.id && libraryList.value.length) throw new Error(t('De momento solo se puede conectar un servidor propio: cambia el que hay o quítalo antes.'))
    const username = input.username.trim()
    const secret = input.secret ? input.secret.trim()
      : username !== connection.username || !token.value ? await loadToken(username) : token.value
    if (!secret) throw new Error(t('Hace falta la contraseña de aplicación.'))
    // a new or changed address (or credential) must answer before it is kept: else a typo in it would be taken
    // for being offline and the app would wait for a server that does not exist
    const url = input.url.trim().replace(/\/+$/, '')
    if (!input.id || url !== connection.url || username !== connection.username || input.secret) {
      try {
        await new Api(url, () => Api.basic(username, secret)).ensureConnected()
      } catch (err: any) {
        throw new Error(err?.status === 401 ? t('No reconoce ese usuario o esa contraseña de aplicación.') : t('No se pudo conectar: {error}', { error: err?.message || String(err) }))
      }
    }
    token.value = secret
    Object.assign(connection, { url, username, name: input.name })
    await saveConnection(connection)
    if (input.secret) await saveToken(username, token.value)
    if (!(await connect())) throw new Error(serverError.value || t('No se pudo conectar.'))
    return libraryList.value[0]
  },
  async remove() {
    await forgetToken(connection.username)
    token.value = ''
    serverError.value = ''
    Object.assign(connection, { url: '', username: '', name: '' })
    await saveConnection(connection)
    await use(false)
    listLibraries()
  },
}
/** the app's library and the ones the page keeps (Suwayomi…), together */
const allLibraries = withDeviceLibraries(libraries, net)
const provided = shallowReactive<{ store: Store | null }>({ store: null })
function provideStore(s: Store) { provided.store = s }
provide(STORE, new Proxy({} as Store, { get: (_, key) => (provided.store as any)?.[key] }))

// ---- files of this computer: a double click in the Explorer, a second launch, files dropped here.
// They go on the shelf («Archivos sueltos», or their folder if it is one of the shelf's) and stay. ----
const OPENABLE = /\.(cbz|cbr|cb7|cbt|zip|rar|7z|tar|pdf|djvu|djv|epub|mobi|azw|azw3|prc|fb2|fbz|txt)$/i
let waiting: string[] = []
async function openLocal(paths: string[]) {
  if (!store.value) { waiting = [...waiting, ...paths]; return }      // still starting: it opens once ready
  const good = paths.filter((p) => OPENABLE.test(p))
  if (!good.length) { notify(t('La Estantería abre cbz, cbr, cb7, cbt, pdf, djvu, epub, mobi, azw3, fb2, fbz y txt de este PC.'), true); return }
  try {
    const items = await shelf.addFiles(good)
    await refresh()
    if (items.length === 1) read(items[0])
    else { notify(plural(items.length, '{n} archivo en tu estantería.', '{n} archivos en tu estantería.')); go({ v: 'library', source: String(items[0].source_id) }) }
  } catch (err: any) {
    notify(t('No se pudo abrir: {error}', { error: err?.message || String(err) }), true)
  }
}
listen<string>('open-file', (e) => openLocal([e.payload]))
getCurrentWebview().onDragDropEvent((e) => {
  if (e.payload.type === 'drop' && e.payload.paths.length) openLocal(e.payload.paths)
})
watch(store, (s) => { if (s && waiting.length) { const paths = waiting; waiting = []; openLocal(paths) } })

// without connection, look again every so often (and when Windows says the network is back)
setInterval(() => { if (connected.value && offline.value && !offline.value.state.online) refresh() }, 30000)
window.addEventListener('online', () => { if (connected.value) refresh() })

onMounted(async () => {
  try { version.value = await getVersion() } catch (_) { version.value = 'dev' }
  await lock.lockIfAsked()
  await shelf.load()
  if (appSettings.scanOnStart) shelf.scan().catch(() => {})
  if (!window.location.hash && appSettings.start === 'library') go({ v: 'library' }, true)
  Object.assign(connection, await loadConnection())
  token.value = await loadToken(connection.username)
  await connect()
  const launched = await invoke<string | null>('local_launch_path').catch(() => null)
  if (launched) openLocal([launched])
})
</script>
