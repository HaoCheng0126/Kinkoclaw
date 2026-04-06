import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import vue from "@vitejs/plugin-vue";
import { defineConfig } from "vite";

const here = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  base: "./",
  plugins: [
    vue(),
    {
      name: "strip-file-crossorigin",
      transformIndexHtml: {
        order: "post",
        handler(html) {
          return html.replace(/\s+crossorigin(?=[\s>])/g, "");
        },
      },
    },
  ],
  build: {
    emptyOutDir: true,
    outDir: resolve(here, "../Sources/KinkoClaw/Resources/StageRuntime"),
    sourcemap: false,
    target: "es2022",
  },
});
