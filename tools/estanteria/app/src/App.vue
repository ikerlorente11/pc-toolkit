<template>
  <div class="es" :class="{ 'es-reading': view.v === 'read' }">
    <template v-if="view.v === 'read' && store">
      <ReaderView :key="`read${view.id}`" :id="view.id" :start-page="view.page" />
    </template>
    <template v-else>
      <aside class="es-side" aria-label="Tu estantería">
        <div class="es-brand">
          <span class="es-brand-mark" aria-hidden="true"><i class="es-i es-i-book" aria-hidden="true"></i></span>
          <strong>La Estantería</strong>
        </div>
        <nav class="es-nav">
          <a href="#" :class="{ on: view.v === 'home' }" @click.prevent="go({ v: 'home' })"><span class="es-ni"><i class="es-i es-i-home" aria-hidden="true"></i></span> Inicio</a>
          <a href="#" :class="{ on: view.v === 'library' }" @click.prevent="go({ v: 'library' })"><span class="es-ni"><i class="es-i es-i-grid" aria-hidden="true"></i></span> Biblioteca</a>
          <a href="#" :class="{ on: view.v === 'catalogs' || view.v === 'catalog' }" @click.prevent="go({ v: 'catalogs' })"><span class="es-ni"><i class="es-i es-i-cloud" aria-hidden="true"></i></span> Catálogos</a>
          <a href="#" :class="{ on: view.v === 'sources' }" @click.prevent="go({ v: 'sources' })"><span class="es-ni"><i class="es-i es-i-server" aria-hidden="true"></i></span> Bibliotecas</a>
          <a href="#" :class="{ on: view.v === 'downloads' }" @click.prevent="go({ v: 'downloads' })">
            <span class="es-ni"><i class="es-i es-i-download" aria-hidden="true"></i></span> Descargas
            <small v-if="offline && jobCount" class="es-muted es-navcount"><span class="es-spin"></span> {{ jobCount }}</small>
            <small v-else-if="offline && offline.count" class="es-muted es-navcount">{{ offline.count }}</small>
          </a>
        </nav>
        <div class="es-lib">
          <div class="es-libh">Series <small class="es-muted">{{ state.series.length }}</small></div>
          <p v-if="!connected" class="es-muted es-small es-libnote">Conecta con tu Archivador para ver tus series.</p>
          <p v-else-if="!state.loaded" class="es-muted es-small es-libnote"><span class="es-spin"></span> Cargando…</p>
          <ul v-else class="es-serieslist">
            <li v-for="s in state.series" :key="s.series">
              <a href="#" :class="{ on: view.v === 'series' && view.name === s.series }" @click.prevent="go({ v: 'series', name: s.series })">
                <Cover :id="s.cover_item" :has="s.cover" class="es-thumb" />
                <span class="es-sname"><span class="es-ellipsis">{{ s.series }}</span><small class="es-muted">{{ s.items }} {{ s.items === 1 ? 'número' : 'números' }}</small></span>
              </a>
            </li>
          </ul>
        </div>
        <a href="#" class="es-back" :class="{ on: view.v === 'setup' }" @click.prevent="go({ v: 'setup' } as any)"><i class="es-i es-i-settings" aria-hidden="true"></i> {{ connection.username ? connection.username : 'Conectar' }} <span class="es-version">· v{{ version }}</span></a>
      </aside>

      <main ref="mainEl" class="es-main">
        <p v-if="offline && !offline.state.online" class="es-offline-banner">
          <i class="es-i es-i-cloud" aria-hidden="true"></i>
          <span>Sin conexión con La Estantería: puedes leer lo descargado. Lo que leas se apunta y se envía al volver.</span>
          <span class="es-grow"></span>
          <button class="es-btn es-small" @click="refresh()">Reintentar</button>
        </p>
        <p v-if="state.error" class="es-banner es-banner-error">{{ state.error }} <button class="es-btn es-small" @click="connect()">Reintentar</button></p>
        <section v-if="view.v === 'setup' || !connected" class="es-page">
          <header class="es-page-head"><h1 class="es-h1">Tu Archivador</h1></header>
          <form class="es-setup" @submit.prevent="save">
            <p class="es-muted">La Estantería lee los cómics y libros de la carpeta «Lectura» de tu nube. Hace falta tu usuario y una <strong>contraseña de aplicación</strong> (en El Archivador: tu cuenta › Contraseñas de aplicación); se guarda en el almacén de credenciales de Windows.</p>
            <label>Dirección del servicio <input v-model="form.url" type="url" placeholder="https://estanteria.pistation.dev" required /></label>
            <label>Usuario <input v-model="form.username" type="text" autocomplete="username" required /></label>
            <label>Contraseña de aplicación <input v-model="form.token" type="password" autocomplete="current-password" :placeholder="connection.username && !form.token ? '(guardada; escribe otra para cambiarla)' : ''" /></label>
            <div class="es-setup-actions">
              <button class="es-btn es-primary" type="submit" :disabled="saving"><span v-if="saving" class="es-spin"></span> Conectar</button>
              <button v-if="connected" class="es-btn" type="button" @click="disconnect">Olvidar</button>
            </div>
          </form>
        </section>
        <template v-else-if="store">
          <HomeView v-if="view.v === 'home'" />
          <LibraryView v-else-if="view.v === 'library'" :q="view.q || ''" :kind="view.kind" :sort="view.sort" :folder="view.folder" :source="view.source" />
          <SeriesView v-else-if="view.v === 'series'" :key="`s${view.name}`" :name="view.name" />
          <ItemView v-else-if="view.v === 'item'" :key="`i${view.id}`" :id="view.id" />
          <SourcesView v-else-if="view.v === 'sources'" />
          <CatalogsView v-else-if="view.v === 'catalogs'" />
          <DownloadsView v-else-if="view.v === 'downloads'" />
          <CatalogView v-else-if="view.v === 'catalog'" :key="`c${view.kind}`" :kind="view.kind" :path="view.path" :q="view.q" />
        </template>
      </main>
    </template>
    <div v-if="toast.text" :class="['es-toast', { 'es-toast-error': toast.error }]" role="status">{{ toast.text }}</div>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, provide, reactive, ref, shallowRef, watch } from 'vue'
import { getVersion } from '@tauri-apps/api/app'
import { Api, CatalogView, CatalogsView, Cover, DownloadsView, HomeView, Offline, ImageCache, ItemView, LibraryView, ReaderView, SeriesView, SourcesView, STORE, createState, queryFromView,
         viewFromQuery, type Item, type Store, type View } from 'estanteria-viewer'
import { forgetToken, loadConnection, loadToken, saveConnection, saveToken, type Connection } from './lib/settings'
import { accountKey, desktopBackend } from './lib/offline'

/**
 * The desktop shell of La Estantería: the same library and readers as the web, against the
 * service of the user's Archivador with their app token (HTTP basic). The page shown lives in the
 * URL's hash (#v=series&name=…), so back and forward work.
 */
const version = ref('')
const connection = reactive<Connection>({ url: '', username: '' })
const form = reactive({ url: '', username: '', token: '' })
const connected = ref(false)
const saving = ref(false)
const state = createState()
const toast = reactive({ text: '', error: false })
const mainEl = ref<HTMLElement>()
let toastTimer: any = null
let token = ''

// ---- navigation in the hash ----
const hash = ref(window.location.hash)
window.addEventListener('hashchange', () => { hash.value = window.location.hash })
const view = computed<View | { v: 'setup' }>(() => {
  const params = Object.fromEntries(new URLSearchParams(hash.value.replace(/^#/, '')))
  return params.v === 'setup' ? { v: 'setup' } : viewFromQuery(params)
})
function go(next: View | { v: 'setup' }, replace = false) {
  const query = next.v === 'setup' ? 'v=setup' : new URLSearchParams(queryFromView(next as View)).toString()
  if (replace) window.history.replaceState(null, '', `#${query}`)
  else window.location.hash = query
  hash.value = `#${query}`
}
function back() {
  if (window.history.length > 1) window.history.back()
  else go({ v: 'home' })
}
watch(() => hash.value, () => mainEl.value?.scrollTo({ top: 0 }))

function notify(text: string, error = false) {
  toast.text = text
  toast.error = error
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => { toast.text = '' }, error ? 7000 : 3500)
}

// ---- the service ----
const api = new Api('', () => '')
let current: Api = api
const store = ref<Store | null>(null)
// ---- reading without connection: one keeper per account (its downloads go on across reconnections) ----
const keepers = new Map<string, Offline>()
const offline = shallowRef<Offline | null>(null)
const jobCount = computed(() => (offline.value ? Object.keys(offline.value.state.jobs).length : 0))
function keeperFor(): Offline {
  const account = accountKey(connection.username, connection.url)
  let keeper = keepers.get(account)
  if (!keeper) {
    keeper = new Offline(desktopBackend(account, () => connection.url, () => Api.basic(connection.username, token)))
    keepers.set(account, keeper)
  }
  return keeper
}

function makeStore(): Store {
  current = new Api(connection.url, () => Api.basic(connection.username, token))
  const keeper = keeperFor()
  keeper.attach(current)
  offline.value = keeper
  const covers = new ImageCache(current, 400)
  const pages = new ImageCache(current, 24)
  const s: Store = { api: current, covers, pages, readingRoot: 'Lectura', state, refresh, go: go as any, back, notify, read, offline: keeper }
  return s
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
    state.error = `No se pudo hablar con La Estantería: ${err?.message || err}`
  }
}
async function connect() {
  state.error = ''
  if (!connection.url || !connection.username || !token) { connected.value = false; return }
  const s = makeStore()
  await offline.value?.load()
  try {
    await current.ensureConnected()
    store.value = s
    provideStore(s)
    connected.value = true
    state.connected = true
    await refresh()
  } catch (err: any) {
    connected.value = false
    state.error = err?.status === 401 ? 'El Archivador no reconoce ese usuario o esa contraseña de aplicación.' : `No se pudo conectar: ${err?.message || err}`
  }
}
const provided = reactive<{ store: Store | null }>({ store: null })
function provideStore(s: Store) { provided.store = s }
provide(STORE, new Proxy({} as Store, { get: (_, key) => (provided.store as any)?.[key] }))

async function save() {
  saving.value = true
  const newToken = form.token.trim()
  connection.url = form.url.trim().replace(/\/+$/, '')
  connection.username = form.username.trim()
  if (newToken) token = newToken
  else if (!token) token = await loadToken(connection.username)
  await saveConnection(connection)
  if (newToken) await saveToken(connection.username, newToken)
  form.token = ''
  await connect()
  saving.value = false
  if (connected.value) { notify(`Conectado como ${connection.username}.`); go({ v: 'home' }, true) }
}
async function disconnect() {
  await forgetToken(connection.username)
  token = ''
  connected.value = false
  state.connected = false
  state.loaded = false
  state.series = []
  notify('Olvidado.')
}

// without connection, look again every so often (and when Windows says the network is back)
setInterval(() => { if (connected.value && offline.value && !offline.value.state.online) refresh() }, 30000)
window.addEventListener('online', () => { if (connected.value) refresh() })

onMounted(async () => {
  try { version.value = await getVersion() } catch (_) { version.value = 'dev' }
  Object.assign(connection, await loadConnection())
  form.url = connection.url
  form.username = connection.username
  token = await loadToken(connection.username)
  await connect()
  if (!connected.value && view.value.v !== 'setup') go({ v: 'setup' }, true)
})
</script>
