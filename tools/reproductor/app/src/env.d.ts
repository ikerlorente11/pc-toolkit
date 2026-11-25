/// <reference types="vite/client" />
interface ImportMetaEnv {
  /** the app's credentials in Telegram's API (my.telegram.org), set when building: see the README */
  readonly VITE_TELEGRAM_API_ID?: string
  readonly VITE_TELEGRAM_API_HASH?: string
}
declare module '*.vue' {
  import type { DefineComponent } from 'vue'
  const component: DefineComponent<{}, {}, any>
  export default component
}
