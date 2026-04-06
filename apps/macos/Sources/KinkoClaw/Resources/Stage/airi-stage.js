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
  app: document.getElementById("app"),
  stageScene: document.getElementById("stageScene"),
  character: document.getElementById("character"),
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
  voiceMeter: document.getElementById("voiceMeter"),
  toast: document.getElementById("toast"),
  mouth: document.getElementById("mouth"),
};

const bridge = window.KinkoClawNativeBridge ?? {
  postMessage(payload) {
    window.webkit?.messageHandlers?.kinkoClawStageBridge?.postMessage(payload);
  },
};

function post(type, extra = {}) {
  bridge.postMessage({ type, ...extra });
}

function renderTheme() {
  if (!state.pack) {return;}
  const root = document.documentElement.style;
  root.setProperty("--accent", state.pack.accentHex);
  root.setProperty("--hair", state.pack.assets.hairHex);
  root.setProperty("--hair-shadow", state.pack.assets.hairShadowHex);
  root.setProperty("--skin", state.pack.assets.skinHex);
  root.setProperty("--eye", state.pack.assets.eyeHex);
  root.setProperty("--ribbon", state.pack.assets.ribbonHex);
  root.setProperty("--outfit", state.pack.assets.outfitHex);
  root.setProperty("--accent-glow", state.pack.assets.glowHex);
  refs.packTitle.textContent = state.pack.displayName;
  refs.personaChip.textContent = state.pack.interactionProfile.personaLabel;
  refs.subtitlePrefix.textContent = state.pack.voiceProfile.subtitlePrefix;
}

function formatTime(timestamp) {
  if (!timestamp) {return "now";}
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

function renderMessages() {
  refs.dialogueFeed.innerHTML = "";
  const messages = state.messages.slice(-14);
  if (messages.length === 0) {
    const empty = document.createElement("div");
    empty.className = "message-bubble";
    empty.innerHTML = `
      <div class="message-meta"><span>Stage</span><span>Waiting</span></div>
      <div class="message-text">Connect KinkoClaw to an OpenClaw gateway, then the AIRI-style stage will replay the current \`main\` conversation here.</div>
    `;
    refs.dialogueFeed.appendChild(empty);
    return;
  }

  messages.forEach((message) => {
    const bubble = document.createElement("article");
    bubble.className = `message-bubble ${message.role === "user" ? "user" : "assistant"}`;
    bubble.innerHTML = `
      <div class="message-meta">
        <span>${message.role === "user" ? "You" : "AIRI"}</span>
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
  document.documentElement.style.setProperty("--voice-level", String(Math.max(0.08, Math.min(1, voice.level || 0))));

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

function renderCharacter() {
  const classes = [
    "is-disconnected",
    "is-listening",
    "is-hearing",
    "is-thinking",
    "is-replying",
    "is-speaking",
    "is-error",
  ];
  refs.character.classList.remove(...classes);
  refs.character.classList.add(`is-${state.presenceState}`);

  const voiceText = state.voice.transcript?.trim();
  const streamingText = state.streamingAssistantText?.trim();
  const subtitleText =
    streamingText ||
    voiceText ||
    state.messages.at(-1)?.text ||
    state.statusMessage ||
    "Stage is waiting for your gateway.";
  refs.subtitleText.textContent = subtitleText;

  const mouthScale =
    state.presenceState === "speaking" || state.presenceState === "hearing" || state.presenceState === "listening"
      ? 1 + Math.max(0.12, state.voice.level || 0) * 2.1
      : state.presenceState === "replying"
        ? 1.3
        : state.presenceState === "thinking"
          ? 0.85
          : 1;
  refs.mouth.style.transform = `scaleY(${mouthScale})`;
}

function renderAll() {
  renderTheme();
  renderStatus();
  renderMessages();
  renderStream();
  renderVoice();
  renderCharacter();
}

function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function showToast(message) {
  if (!message) {return;}
  refs.toast.hidden = false;
  refs.toast.textContent = message;
  clearTimeout(state.toastTimer);
  state.toastTimer = window.setTimeout(() => {
    refs.toast.hidden = true;
  }, 3600);
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
      if (state.voice.presence === "listening" || state.voice.presence === "hearing" || state.voice.presence === "speaking") {
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

function submitMessage() {
  const text = refs.messageInput.value.trim();
  if (!text) {return;}
  refs.messageInput.value = "";
  post("chat.send", { text });
}

function beginVoice() {
  if (state.voiceHeld) {return;}
  state.voiceHeld = true;
  refs.voiceButton.classList.add("is-active");
  post("voice.begin");
}

function endVoice(cancel = false) {
  if (!state.voiceHeld) {return;}
  state.voiceHeld = false;
  refs.voiceButton.classList.remove("is-active");
  post(cancel ? "voice.cancel" : "voice.end");
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
    if (type) {post(type);}
  });
});

refs.stageScene.addEventListener("pointermove", (event) => {
  const rect = refs.stageScene.getBoundingClientRect();
  const x = (event.clientX - rect.left - rect.width / 2) / rect.width;
  const y = (event.clientY - rect.top - rect.height / 2) / rect.height;
  document.documentElement.style.setProperty("--cursor-x", `${x * 36}px`);
  document.documentElement.style.setProperty("--cursor-y", `${y * 32}px`);
});

refs.stageScene.addEventListener("pointerleave", () => {
  document.documentElement.style.setProperty("--cursor-x", "0px");
  document.documentElement.style.setProperty("--cursor-y", "0px");
});

window.KinkoClawStage = { receive };
post("stage.ready");
renderAll();
