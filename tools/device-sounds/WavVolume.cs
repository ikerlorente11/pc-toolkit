// WavVolume.cs - Copia un archivo WAV PCM cambiando su volumen. Windows no tiene volumen propio para
// los sonidos de conectar/desconectar (comparten "Sonidos del sistema"), así que la herramienta usa
// una copia con el volumen elegido. Lo carga common.ps1 con Add-Type.
using System;
using System.IO;
using System.Text;

namespace PcToolkit.DeviceSounds {
    public static class WavVolume {
        // percent 0-100 con curva cuadrática (el 50 % suena a "la mitad", no casi igual que el 100 %).
        // Devuelve false si el formato no es PCM de 16 bits (entonces no se copia).
        public static bool Scale(string source, string target, int percent) {
            byte[] b = File.ReadAllBytes(source);
            if (b.Length < 12 || Encoding.ASCII.GetString(b, 0, 4) != "RIFF" || Encoding.ASCII.GetString(b, 8, 4) != "WAVE") return false;
            double p = Math.Max(0, Math.Min(100, percent)) / 100.0;
            double factor = p * p;
            int format = 0, bits = 0;
            bool scaled = false;
            int pos = 12;
            while (pos + 8 <= b.Length) {
                string id = Encoding.ASCII.GetString(b, pos, 4);
                int size = BitConverter.ToInt32(b, pos + 4);
                int data = pos + 8;
                if (size < 0 || data > b.Length) break;
                if (id == "fmt ") {
                    format = BitConverter.ToUInt16(b, data);
                    bits = BitConverter.ToUInt16(b, data + 14);
                } else if (id == "data") {
                    // 1 = PCM; 0xFFFE = WAVE_FORMAT_EXTENSIBLE (los WAV de Windows suelen serlo, con PCM dentro)
                    if (!((format == 1 || format == 0xFFFE) && bits == 16)) return false;
                    int end = Math.Min(b.Length, data + size);
                    for (int i = data; i + 1 < end; i += 2) {
                        int v = (int)Math.Round(BitConverter.ToInt16(b, i) * factor);
                        b[i] = (byte)(v & 0xFF);
                        b[i + 1] = (byte)((v >> 8) & 0xFF);
                    }
                    scaled = true;
                }
                pos = data + size + (size & 1);
            }
            if (!scaled) return false;
            File.WriteAllBytes(target, b);
            return true;
        }
    }
}
