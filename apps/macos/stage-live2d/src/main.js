import { createApp } from "vue";

import App from "./App.vue";
import "./style.css";

const stageMode = new URLSearchParams(window.location.search).get("mode") === "pet" ? "pet" : "stage";

document.documentElement.dataset.mode = stageMode;
document.body.dataset.mode = stageMode;

const app = createApp(App, { stageMode });
const vm = app.mount("#app");

window.KinkoClawStage = {
  receive(event) {
    vm.receive(event);
  },
};

window.__KINKOCLAW_STAGE_FLUSH__?.();
window.KinkoClawNativeBridge?.postMessage?.({ type: "stage.ready" });
