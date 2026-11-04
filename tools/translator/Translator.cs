// Translator.cs - Peticiones del Traductor al servicio web de Google Translate (el mismo que usa la
// web, sin clave). Asíncronas: el gestor no se congela mientras espera y comprueba la tarea con un reloj.
using System;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace PcToolkit.Translator {
    public static class Http {
        static readonly HttpClient Client;

        static Http() {
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            Client = new HttpClient();
            Client.Timeout = TimeSpan.FromSeconds(12);
        }

        // Devuelve el JSON de Google: [frases traducidas, diccionario (palabras sueltas), idioma detectado, ...]
        // source = "auto" para detectarlo. uiLang = idioma de las categorías del diccionario (sustantivo...).
        public static Task<string> Translate(string text, string source, string target, string uiLang) {
            string url = "https://translate.googleapis.com/translate_a/single?client=gtx&dt=t&dt=bd" +
                         "&sl=" + Uri.EscapeDataString(source) +
                         "&tl=" + Uri.EscapeDataString(target) +
                         "&hl=" + Uri.EscapeDataString(uiLang);
            // POST para que quepan textos largos
            return Post(url, "q=" + Uri.EscapeDataString(text));
        }

        static async Task<string> Post(string url, string body) {
            using (StringContent content = new StringContent(body, Encoding.UTF8, "application/x-www-form-urlencoded"))
            using (HttpResponseMessage response = await Client.PostAsync(url, content).ConfigureAwait(false)) {
                response.EnsureSuccessStatusCode();
                byte[] bytes = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                return Encoding.UTF8.GetString(bytes);
            }
        }
    }
}
