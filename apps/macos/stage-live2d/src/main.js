import "./style.css";

import JSZip from "jszip";
import * as PIXI from "pixi.js";

window.PIXI = PIXI;

import {
  Cubism4ModelSettings,
  Live2DFactory,
  Live2DModel,
  MotionPriority,
  ZipLoader,
} from "pixi-live2d-display/cubism4";

const stageMode = new URLSearchParams(window.location.search).get("mode") === "pet" ? "pet" : "stage";
const isPetMode = stageMode === "pet";

document.documentElement.dataset.mode = stageMode;
document.body.dataset.mode = stageMode;

ZipLoader.zipReader = (data, _url) => JSZip.loadAsync(data);

const defaultCreateSettings = ZipLoader.createSettings.bind(ZipLoader);
ZipLoader.createSettings = async (reader) => {
  const filePaths = Object.keys(reader.files);
  if (!filePaths.some((file) => file.endsWith(".model3.json") || file.endsWith(".model.json"))) {
    return createFakeSettings(filePaths);
  }
  return defaultCreateSettings(reader);
};

ZipLoader.readText = (jsZip, path) => {
  const file = jsZip.file(path);
  if (!file) {
    throw new Error(`Cannot find file: ${path}`);
  }
  return file.async("text");
};

ZipLoader.getFilePaths = (jsZip) => {
  const paths = [];
  jsZip.forEach((relativePath) => paths.push(relativePath));
  return Promise.resolve(paths);
};

ZipLoader.getFiles = (jsZip, paths) =>
  Promise.all(
    paths.map(async (path) => {
      const fileName = path.slice(path.lastIndexOf("/") + 1);
      const blob = await jsZip.file(path).async("blob");
      return new File([blob], fileName);
    }),
  );

const state = {
  connectionStatus: "disconnected",
  statusMessage: "Not connected",
  presenceState: "disconnected",
  pack: null,
  messages: [],
  streamingAssistantText: "",
  voice: {
    presence: "idle",
    transcript: "",
    level: 0,
    errorMessage: null,
    permissionsGranted: false,
  },
  toastTimer: null,
  voiceHeld: false,
};

const refs = {
  stageScene: document.getElementById("stageScene"),
  live2dFrame: document.getElementById("live2dFrame"),
  live2dHost: document.getElementById("live2dHost"),
  modelFallback: document.getElementById("modelFallback"),
  subtitleBubble: document.getElementById("subtitleBubble"),
  subtitlePrefix: document.getElementById("subtitlePrefix"),
  subtitleText: document.getElementById("subtitleText"),
  personaChip: document.getElementById("personaChip"),
  connectionChip: document.getElementById("connectionChip"),
  packTitle: document.getElementById("packTitle"),
  presencePill: document.getElementById("presencePill"),
  statusCopy: document.getElementById("statusCopy"),
  streamText: document.getElementById("streamText"),
  transcriptCopy: document.getElementById("transcriptCopy"),
  dialogueFeed: document.getElementById("dialogueFeed"),
  composer: document.getElementById("composer"),
  messageInput: document.getElementById("messageInput"),
  voiceButton: document.getElementById("voiceButton"),
  toast: document.getElementById("toast"),
};

const bridge = window.KinkoClawNativeBridge ?? {
  postMessage(payload) {
    window.webkit?.messageHandlers?.kinkoClawStageBridge?.postMessage(payload);
  },
};

function post(type, extra = {}) {
  bridge.postMessage({ type, ...extra });
}

function basename(path) {
  return path.split(/[\\/]/).pop();
}

function createFakeSettings(files) {
  const mocFiles = files.filter((file) => file.endsWith(".moc3"));
  if (mocFiles.length !== 1) {
    throw new Error(`Expected exactly one moc3 file, got ${mocFiles.length}`);
  }

  const mocFile = mocFiles[0];
  const modelName = basename(mocFile).replace(/\.moc3?/, "");
  const textures = files.filter((file) => file.endsWith(".png"));
  const physics = files.find((file) => file.includes("physics"));
  const pose = files.find((file) => file.includes("pose"));
  const motions = files.filter((file) => file.endsWith(".mtn") || file.endsWith(".motion3.json"));

  const settings = new Cubism4ModelSettings({
    url: `${modelName}.model3.json`,
    Version: 3,
    FileReferences: {
      Moc: mocFile,
      Textures: textures,
      Physics: physics,
      Pose: pose,
      Motions: motions.length
        ? {
            "": motions.map((motion) => ({ File: motion })),
          }
        : undefined,
    },
  });
  settings.name = modelName;
  settings._objectURL = `example://${settings.url}`;
  return settings;
}

class Live2DStageRuntime {
  constructor(host, fallback) {
    this.host = host;
    this.fallback = fallback;
    this.app = null;
    this.model = null;
    this.modelURL = null;
    this.presenceState = "disconnected";
    this.motionPresence = null;
    this.mouthTarget = 0;
    this.mouthCurrent = 0;
    this.frameHandle = 0;
    this.resizeObserver = null;
    this.lastMotionAt = 0;
    this.naturalModelWidth = 0;
    this.naturalModelHeight = 0;
    this.playLoop = this.playLoop.bind(this);
  }

  async init() {
    if (this.app) {
      return;
    }

    Live2DModel.registerTicker(PIXI.Ticker);
    PIXI.extensions.add(PIXI.TickerPlugin);

    this.app = new PIXI.Application({
      autoStart: true,
      backgroundAlpha: 0,
      antialias: true,
      autoDensity: true,
      resolution: Math.min(window.devicePixelRatio || 1, 2),
      resizeTo: this.host,
    });

    this.host.replaceChildren(this.app.view);
    this.resizeObserver = new ResizeObserver(() => this.fitModel());
    this.resizeObserver.observe(this.host);
    this.frameHandle = window.requestAnimationFrame(() => this.playLoop());
  }

  destroyModel() {
    if (!this.model || !this.app) {
      return;
    }

    try {
      this.app.stage.removeChild(this.model);
      this.model.destroy();
    } catch (error) {
      console.warn("Failed to destroy old Live2D model", error);
    }

    this.model = null;
    this.motionPresence = null;
    this.naturalModelWidth = 0;
    this.naturalModelHeight = 0;
  }

  async load(modelURL) {
    await this.init();
    if (this.modelURL === modelURL && this.model) {
      return;
    }

    this.showFallback("Loading AIRI Live2D…");
    this.destroyModel();
    this.modelURL = modelURL;

    const model = new Live2DModel();
    await Live2DFactory.setupLive2DModel(model, modelURL, { autoInteract: false });

    this.model = model;
    this.naturalModelWidth = Math.max(1, model.width);
    this.naturalModelHeight = Math.max(1, model.height);
    this.model.anchor.set(0.5, 1);
    this.app.stage.addChild(model);
    this.fitModel();
    this.hideFallback();

    const motionManager = model.internalModel?.motionManager;
    motionManager?.on?.("motionFinish", () => {
      if (this.presenceState === "idle") {
        void this.playPresenceMotion("idle", true);
      }
    });
  }

  fitModel() {
    if (!this.model || !this.app) {
      return;
    }

    const width = this.host.clientWidth || this.app.renderer.width;
    const height = this.host.clientHeight || this.app.renderer.height;
    const modelWidth = Math.max(1, this.naturalModelWidth || this.model.width);
    const modelHeight = Math.max(1, this.naturalModelHeight || this.model.height);

    if (isPetMode) {
      const scale = Math.min((width * 1.22) / modelWidth, (height * 1.14) / modelHeight);
      this.model.scale.set(scale);
      this.model.x = width * 0.5;
      this.model.y = height * 1.015;
      return;
    }

    const scale = Math.min((width * 0.84) / modelWidth, (height * 0.92) / modelHeight);

    this.model.scale.set(scale);
    this.model.x = width * 0.5;
    this.model.y = height * 0.985;
  }

  setPointerFocus(x, y) {
    if (!this.model?.focus || isPetMode) {
      return;
    }

    const strength = Math.max(
      0,
      Math.min(0.55, state.pack?.interactionProfile?.pointerFollowStrength ?? 0.32),
    );
    const focusX = Math.max(-0.34, Math.min(0.34, x * strength));
    const focusY = Math.max(-0.28, Math.min(0.28, y * strength * 0.82));
    this.model.focus(focusX, focusY);
  }

  setMouthTarget(value) {
    this.mouthTarget = Math.max(0, Math.min(1.1, value));
  }

  setPresenceState(nextState) {
    if (!nextState) {
      return;
    }

    const changed = this.presenceState !== nextState;
    this.presenceState = nextState;
    if (changed) {
      void this.playPresenceMotion(nextState);
    }
  }

  async playPresenceMotion(presence, allowRepeat = false) {
    if (!this.model || !state.pack?.model?.motions) {
      return;
    }

    const now = Date.now();
    if (!allowRepeat && this.motionPresence === presence && now - this.lastMotionAt < 1200) {
      return;
    }

    const token = pickMotionToken(state.pack.model.motions[presence] ?? state.pack.model.motions.idle ?? []);
    if (!token) {
      return;
    }

    const [group, rawIndex] = token.split(":");
    const index = Number.parseInt(rawIndex ?? "0", 10) || 0;

    try {
      await this.model.motion(group, index, MotionPriority.FORCE);
      this.motionPresence = presence;
      this.lastMotionAt = now;
    } catch (error) {
      console.warn(`Failed to play motion ${token}`, error);
    }
  }

  async tapBody() {
    if (!this.model) {
      return;
    }

    try {
      await this.model.motion("Tap@Body", 0, MotionPriority.FORCE);
    } catch (error) {
      console.warn("Tap@Body motion failed", error);
      void this.playPresenceMotion("replying", true);
    }
  }

  playLoop() {
    const coreModel = this.model?.internalModel?.coreModel;
    if (coreModel) {
      this.mouthCurrent += (this.mouthTarget - this.mouthCurrent) * 0.22;
      coreModel.setParameterValueById("ParamMouthOpenY", this.mouthCurrent);
    }

    this.frameHandle = window.requestAnimationFrame(() => this.playLoop());
  }

  showFallback(message) {
    this.fallback.textContent = message;
    this.fallback.classList.remove("is-hidden");
  }

  hideFallback() {
    this.fallback.classList.add("is-hidden");
  }
}

const runtime = new Live2DStageRuntime(refs.live2dHost, refs.modelFallback);

function resolveModelURL(rawPath) {
  const safePath = rawPath?.trim() || "models/hiyori_free_zh.zip";
  return new URL(safePath, window.location.href).href;
}

function pickMotionToken(tokens) {
  if (!Array.isArray(tokens) || tokens.length === 0) {
    return null;
  }
  return tokens[Math.floor(Math.random() * tokens.length)];
}

function renderTheme() {
  if (!state.pack) {
    return;
  }

  const root = document.documentElement.style;
  root.setProperty("--accent", state.pack.accentHex);
  root.setProperty("--accent-glow", state.pack.assets.glowHex);
  refs.packTitle.textContent = state.pack.displayName;
  refs.personaChip.textContent = state.pack.interactionProfile.personaLabel;
  refs.subtitlePrefix.textContent = state.pack.voiceProfile.subtitlePrefix;
}

function formatTime(timestamp) {
  if (!timestamp) {
    return "now";
  }

  try {
    const millis = timestamp > 1e12 ? timestamp : timestamp * 1000;
    return new Date(millis).toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return "now";
  }
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function renderMessages() {
  refs.dialogueFeed.innerHTML = "";
  const messages = state.messages.slice(-14);

  if (messages.length === 0) {
    const empty = document.createElement("div");
    empty.className = "message-bubble assistant";
    empty.innerHTML = `
      <div class="message-meta"><span>Stage</span><span>Waiting</span></div>
      <div class="message-text">Connect KinkoClaw to an OpenClaw gateway, then the real AIRI Hiyori Live2D model will replay the current \`main\` conversation here.</div>
    `;
    refs.dialogueFeed.appendChild(empty);
    return;
  }

  messages.forEach((message) => {
    const bubble = document.createElement("article");
    bubble.className = `message-bubble ${message.role === "user" ? "user" : "assistant"}`;
    bubble.innerHTML = `
      <div class="message-meta">
        <span>${message.role === "user" ? "You" : state.pack?.voiceProfile.subtitlePrefix ?? "AIRI"}</span>
        <span>${message.pending ? "sending" : formatTime(message.timestamp)}</span>
      </div>
      <div class="message-text">${escapeHtml(message.text)}</div>
    `;
    refs.dialogueFeed.appendChild(bubble);
  });

  refs.dialogueFeed.scrollTop = refs.dialogueFeed.scrollHeight;
}

function renderStatus() {
  refs.connectionChip.textContent = state.connectionStatus;
  refs.presencePill.textContent = state.presenceState;
  refs.statusCopy.textContent = state.statusMessage;
}

function renderVoice() {
  const voice = state.voice;
  document.documentElement.style.setProperty("--voice-level", String(Math.max(0.12, Math.min(1, voice.level || 0))));

  if (voice.errorMessage) {
    refs.transcriptCopy.textContent = voice.errorMessage;
  } else if (voice.transcript) {
    refs.transcriptCopy.textContent = voice.transcript;
  } else {
    const copy = {
      idle: "Voice is idle.",
      listening: "Listening for your microphone input…",
      hearing: "Speech recognition is capturing your words…",
      speaking: "System voice is speaking the latest assistant reply…",
      error: "Voice pipeline needs attention.",
    };
    refs.transcriptCopy.textContent = copy[voice.presence] ?? "Voice is idle.";
  }
}

function renderStream() {
  refs.streamText.textContent = state.streamingAssistantText?.trim() || "No active reply";
}

function computeSubtitleText() {
  return (
    state.streamingAssistantText?.trim() ||
    state.voice.transcript?.trim() ||
    state.messages.at(-1)?.text ||
    state.statusMessage ||
    "Stage is waiting for your gateway."
  );
}

function computeMouthTarget() {
  const level = Math.max(0, Math.min(1, state.voice.level || 0));
  switch (state.presenceState) {
    case "speaking":
    case "hearing":
    case "listening":
      return 0.08 + level * 1.05;
    case "replying":
      return 0.18 + level * 0.35;
    default:
      return level * 0.12;
  }
}

async function syncLive2D() {
  if (!state.pack) {
    return;
  }

  try {
    await runtime.load(resolveModelURL(state.pack.model.modelPath));
    runtime.setPresenceState(state.presenceState);
    runtime.setMouthTarget(computeMouthTarget());
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    runtime.showFallback(`Live2D failed to load.\n${message}`);
    showToast(message);
  }
}

function renderStage() {
  refs.subtitleText.textContent = computeSubtitleText();
  void syncLive2D();
}

function renderAll() {
  renderTheme();
  renderStatus();
  renderMessages();
  renderStream();
  renderVoice();
  renderStage();
}

function showToast(message) {
  if (!message) {
    return;
  }

  refs.toast.hidden = false;
  refs.toast.textContent = message;
  clearTimeout(state.toastTimer);
  state.toastTimer = window.setTimeout(() => {
    refs.toast.hidden = true;
  }, 3600);
}

function submitMessage() {
  const text = refs.messageInput.value.trim();
  if (!text) {
    return;
  }
  refs.messageInput.value = "";
  post("chat.send", { text });
}

function beginVoice() {
  if (state.voiceHeld) {
    return;
  }
  state.voiceHeld = true;
  refs.voiceButton.classList.add("is-active");
  post("voice.begin");
}

function endVoice(cancel = false) {
  if (!state.voiceHeld) {
    return;
  }
  state.voiceHeld = false;
  refs.voiceButton.classList.remove("is-active");
  post(cancel ? "voice.cancel" : "voice.end");
}

function receive(event) {
  switch (event?.type) {
    case "stage.bootstrap":
      Object.assign(state, {
        connectionStatus: event.payload.connectionStatus,
        statusMessage: event.payload.statusMessage,
        presenceState: event.payload.presenceState,
        pack: event.payload.pack,
        messages: event.payload.messages ?? [],
        streamingAssistantText: event.payload.streamingAssistantText ?? "",
        voice: event.payload.voice ?? state.voice,
      });
      break;
    case "stage.status":
      state.connectionStatus = event.payload.connectionStatus;
      state.statusMessage = event.payload.statusMessage;
      state.presenceState = event.payload.presenceState;
      break;
    case "stage.pack":
      state.pack = event.payload;
      break;
    case "stage.messages":
      state.messages = event.payload.messages ?? [];
      break;
    case "stage.assistant-stream":
      state.streamingAssistantText = event.payload.text ?? "";
      break;
    case "stage.voice":
      state.voice = event.payload;
      if (["listening", "hearing", "speaking"].includes(state.voice.presence)) {
        state.presenceState = state.voice.presence;
      }
      break;
    case "stage.error":
      showToast(event.payload.message);
      break;
    default:
      break;
  }

  renderAll();
}

refs.composer.addEventListener("submit", (event) => {
  event.preventDefault();
  submitMessage();
});

refs.messageInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    submitMessage();
  }
});

refs.voiceButton.addEventListener("pointerdown", (event) => {
  event.preventDefault();
  beginVoice();
});

window.addEventListener("pointerup", () => endVoice(false));
window.addEventListener("pointercancel", () => endVoice(true));
window.addEventListener("blur", () => endVoice(true));

document.querySelectorAll("[data-action]").forEach((button) => {
  button.addEventListener("click", () => {
    const type = button.getAttribute("data-action");
    if (type) {
      post(type);
    }
  });
});

refs.stageScene.addEventListener("pointermove", (event) => {
  if (isPetMode) {
    return;
  }
  const rect = refs.live2dFrame.getBoundingClientRect();
  const x = (event.clientX - rect.left - rect.width / 2) / rect.width;
  const y = (event.clientY - rect.top - rect.height / 2) / rect.height;
  document.documentElement.style.setProperty("--cursor-x", `${x * 12}px`);
  document.documentElement.style.setProperty("--cursor-y", `${y * 10}px`);
  runtime.setPointerFocus(x, y);
});

refs.stageScene.addEventListener("pointerleave", () => {
  document.documentElement.style.setProperty("--cursor-x", "0px");
  document.documentElement.style.setProperty("--cursor-y", "0px");
  runtime.setPointerFocus(0, 0);
});

refs.live2dFrame.addEventListener("click", () => {
  void runtime.tapBody();
});

window.KinkoClawStage = { receive };
window.__KINKOCLAW_STAGE_FLUSH__?.();
post("stage.ready");
renderAll();
