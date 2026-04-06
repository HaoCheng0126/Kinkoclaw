import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { defineConfig } from "vite";

const here = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  base: "./",
  plugins: [
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
