<script setup>
import { computed, nextTick, onMounted, reactive, ref, watch } from "vue";

import { Live2DStageRuntime } from "./live2d-runtime";

const props = defineProps({
  stageMode: {
    type: String,
    default: "stage",
  },
});

const isPetMode = computed(() => props.stageMode === "pet");

const bridge = window.KinkoClawNativeBridge ?? {
  postMessage(payload) {
    window.webkit?.messageHandlers?.kinkoClawStageBridge?.postMessage(payload);
  },
};

const state = reactive({
  connectionStatus: "disconnected",
  statusMessage: "未连接",
  presenceState: "disconnected",
  pack: null,
  availablePacks: [],
  availableThemes: [],
  messages: [],
  streamingAssistantText: "",
  fallbackChatAvailable: false,
  settingsOpen: false,
});

const connectionDraft = reactive({
  mode: "local",
  localPort: 18789,
  sshTarget: "",
  sshIdentityPath: "",
  directGatewayURL: "",
  gatewayAuthTokenRef: "default",
  gatewayAuthToken: "",
  summary: "",
});

const characterDraft = reactive({
  selectedLive2DModelId: "",
  selectedThemeId: "",
  sceneModelScale: 1,
  sceneModelOffsetX: 0,
  sceneModelOffsetY: 0,
});

const personaDraft = reactive({
  characterIdentity: "",
  speakingStyle: "",
  relationshipToUser: "",
  longTermMemoriesText: "",
  constraintsText: "",
});

const composerText = ref("");
const toastMessage = ref("");
const toastVisible = ref(false);
const live2dHost = ref(null);
const modelFallback = ref(null);

let runtime = null;
let toastTimer = 0;

function post(type, extra = {}) {
  bridge.postMessage({ type, ...extra });
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function showToast(message) {
  if (!message) {
    return;
  }

  toastMessage.value = String(message);
  toastVisible.value = true;
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => {
    toastVisible.value = false;
  }, 3600);
}

function escapeText(value) {
  return String(value ?? "");
}

function formatMessageTime(timestamp) {
  if (!timestamp) {
    return "刚刚";
  }

  const millis = timestamp > 1e12 ? timestamp : timestamp * 1000;
  const date = new Date(millis);
  if (Number.isNaN(date.getTime())) {
    return "刚刚";
  }
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function splitLines(value) {
  return String(value ?? "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function resolveAssetURL(path) {
  if (!path) {
    return "";
  }

  try {
    return new URL(path, window.location.href).href;
  } catch {
    return "";
  }
}

const packsById = computed(() =>
  Object.fromEntries(state.availablePacks.map((pack) => [pack.id, pack])),
);

const themesById = computed(() =>
  Object.fromEntries(state.availableThemes.map((theme) => [theme.id, theme])),
);

const selectedTheme = computed(() => {
  if (characterDraft.selectedThemeId && themesById.value[characterDraft.selectedThemeId]) {
    return themesById.value[characterDraft.selectedThemeId];
  }
  return state.availableThemes[0] ?? null;
});

const baseDisplayPack = computed(() => {
  if (characterDraft.selectedLive2DModelId && packsById.value[characterDraft.selectedLive2DModelId]) {
    return packsById.value[characterDraft.selectedLive2DModelId];
  }
  return state.pack;
});

function composePreviewPack(pack, theme) {
  if (!pack || !theme) {
    return pack;
  }

  return {
    ...pack,
    accentHex: theme.accentHex,
    assets: theme.assets ?? pack.assets,
    animationProfile: theme.animationProfile ?? pack.animationProfile,
  };
}

const displayPack = computed(() => composePreviewPack(baseDisplayPack.value, selectedTheme.value));

const themeStyle = computed(() => {
  const pack = displayPack.value;
  if (!pack) {
    return {};
  }

  return {
    "--accent": pack.accentHex,
    "--accent-glow": pack.assets.glowHex,
    "--accent-soft": `${pack.accentHex}22`,
    "--panel-tint": `${pack.accentHex}12`,
    "--bubble-soft": `${pack.accentHex}1f`,
    "--bubble-user": `${pack.assets.glowHex}14`,
    "--grid-line": `${pack.accentHex}16`,
  };
});

const connectionLabel = computed(() => {
  switch (state.connectionStatus) {
    case "connecting":
      return "连接中";
    case "connected":
      return "已连接";
    case "error":
      return "连接失败";
    default:
      return "未连接";
  }
});

const subtitleText = computed(() => {
  const stream = state.streamingAssistantText.trim();
  if (stream) {
    return stream;
  }

  const lastAssistant = [...state.messages].reverse().find((message) => message.role === "assistant");
  if (lastAssistant?.text) {
    return lastAssistant.text;
  }

  return "";
});

const hasSubtitle = computed(() => subtitleText.value.trim().length > 0);

const drawerConnectionFeedback = computed(() => {
  switch (state.connectionStatus) {
    case "connecting":
      return "正在连接现有的 OpenClaw 网关…";
    case "connected":
      return connectionDraft.summary || "网关已连接，舞台固定绑定到 `main` 会话。";
    case "error":
      return state.statusMessage || "网关返回了错误。";
    default:
      return connectionDraft.summary || "在这里连接一个已有的 OpenClaw 网关。";
  }
});

const renderedMessages = computed(() => state.messages.slice(-24));

function computeMouthTarget() {
  switch (state.presenceState) {
    case "replying":
      return 0.24;
    case "thinking":
      return 0.05;
    default:
      return 0.01;
  }
}

function applySettingsPayload(payload) {
  if (!payload) {
    return;
  }

  state.availablePacks = payload.availablePacks ?? state.availablePacks;
  state.availableThemes = payload.availableThemes ?? state.availableThemes;
  state.settingsOpen = Boolean(payload.settingsOpen);

  if (payload.connection) {
    connectionDraft.mode = payload.connection.mode ?? "local";
    connectionDraft.localPort = Number(payload.connection.localPort ?? 18789) || 18789;
    connectionDraft.sshTarget = payload.connection.sshTarget ?? "";
    connectionDraft.sshIdentityPath = payload.connection.sshIdentityPath ?? "";
    connectionDraft.directGatewayURL = payload.connection.directGatewayURL ?? "";
    connectionDraft.gatewayAuthTokenRef = payload.connection.gatewayAuthTokenRef ?? "default";
    connectionDraft.gatewayAuthToken = payload.connection.gatewayAuthToken ?? "";
    connectionDraft.summary = payload.connection.summary ?? "";
  }

  if (payload.sceneFrame) {
    characterDraft.sceneModelScale = Number(payload.sceneFrame.scale ?? 1) || 1;
    characterDraft.sceneModelOffsetX = Number(payload.sceneFrame.offsetX ?? 0) || 0;
    characterDraft.sceneModelOffsetY = Number(payload.sceneFrame.offsetY ?? 0) || 0;
  }

  if (payload.selectedLive2DModelId) {
    characterDraft.selectedLive2DModelId = payload.selectedLive2DModelId;
  } else if (state.pack?.id) {
    characterDraft.selectedLive2DModelId = state.pack.id;
  }

  if (payload.selectedThemeId) {
    characterDraft.selectedThemeId = payload.selectedThemeId;
  } else if (!characterDraft.selectedThemeId && payload.availableThemes?.length) {
    characterDraft.selectedThemeId = payload.availableThemes[0].id;
  }

  if (payload.personaCard) {
    personaDraft.characterIdentity = payload.personaCard.characterIdentity ?? "";
    personaDraft.speakingStyle = payload.personaCard.speakingStyle ?? "";
    personaDraft.relationshipToUser = payload.personaCard.relationshipToUser ?? "";
    personaDraft.longTermMemoriesText = (payload.personaCard.longTermMemories ?? []).join("\n");
    personaDraft.constraintsText = (payload.personaCard.constraints ?? []).join("\n");
  }
}

function receive(event) {
  switch (event?.type) {
    case "stage.bootstrap":
      state.connectionStatus = event.payload.connectionStatus ?? state.connectionStatus;
      state.statusMessage = event.payload.statusMessage ?? state.statusMessage;
      state.presenceState = event.payload.presenceState ?? state.presenceState;
      state.pack = event.payload.pack ?? state.pack;
      state.messages = event.payload.messages ?? [];
      state.streamingAssistantText = event.payload.streamingAssistantText ?? "";
      state.fallbackChatAvailable = Boolean(event.payload.fallbackChatAvailable);
      applySettingsPayload(event.payload.settings);
      break;
    case "stage.status":
      state.connectionStatus = event.payload.connectionStatus ?? state.connectionStatus;
      state.statusMessage = event.payload.statusMessage ?? state.statusMessage;
      state.presenceState = event.payload.presenceState ?? state.presenceState;
      break;
    case "stage.pack":
      state.pack = event.payload ?? state.pack;
      if (!characterDraft.selectedLive2DModelId) {
        characterDraft.selectedLive2DModelId = event.payload?.id ?? "";
      }
      break;
    case "stage.messages":
      state.messages = event.payload.messages ?? [];
      break;
    case "stage.assistant-stream":
      state.streamingAssistantText = event.payload.text ?? "";
      break;
    case "stage.settings":
      applySettingsPayload(event.payload);
      break;
    case "stage.error":
      showToast(event.payload.message);
      break;
    case "stage.toast":
      showToast(event.payload.message);
      break;
    case "chat.pending":
      break;
    default:
      break;
  }
}

async function syncLive2D() {
  if (!runtime || !displayPack.value) {
    return;
  }

  try {
    await runtime.sync({
      pack: displayPack.value,
      presenceState: state.presenceState,
      sceneFrame: {
        scale: characterDraft.sceneModelScale,
        offsetX: characterDraft.sceneModelOffsetX,
        offsetY: characterDraft.sceneModelOffsetY,
      },
      mouthTarget: computeMouthTarget(),
    });
  } catch (error) {
    showToast(error instanceof Error ? error.message : String(error));
  }
}

watch(
  () => ({
    pack: displayPack.value,
    presenceState: state.presenceState,
    stream: state.streamingAssistantText,
    scale: characterDraft.sceneModelScale,
    offsetX: characterDraft.sceneModelOffsetX,
    offsetY: characterDraft.sceneModelOffsetY,
  }),
  () => {
    void syncLive2D();
  },
  { deep: true },
);

function setSettingsOpen(open) {
  state.settingsOpen = Boolean(open);
  post("settings.visibility", { open: state.settingsOpen });
}

function submitMessage() {
  const text = composerText.value.trim();
  if (!text) {
    return;
  }
  composerText.value = "";
  post("chat.send", { text });
}

function saveConnection() {
  post("settings.saveConnection", {
    mode: connectionDraft.mode,
    localPort: Math.round(connectionDraft.localPort || 18789),
    sshTarget: connectionDraft.sshTarget,
    sshIdentityPath: connectionDraft.sshIdentityPath,
    directGatewayURL: connectionDraft.directGatewayURL,
    gatewayAuthTokenRef: connectionDraft.gatewayAuthTokenRef,
    gatewayAuthToken: connectionDraft.gatewayAuthToken,
  });
}

function saveCharacter() {
  post("settings.saveCharacter", {
    selectedLive2DModelId: characterDraft.selectedLive2DModelId,
    selectedThemeId: characterDraft.selectedThemeId,
    sceneModelScale: clamp(Number(characterDraft.sceneModelScale || 1), 0.72, 1.4),
    sceneModelOffsetX: clamp(Number(characterDraft.sceneModelOffsetX || 0), -0.22, 0.22),
    sceneModelOffsetY: clamp(Number(characterDraft.sceneModelOffsetY || 0), -0.22, 0.22),
  });
}

function savePersona() {
  post("settings.savePersona", {
    characterIdentity: personaDraft.characterIdentity,
    speakingStyle: personaDraft.speakingStyle,
    relationshipToUser: personaDraft.relationshipToUser,
    longTermMemories: splitLines(personaDraft.longTermMemoriesText),
    constraints: splitLines(personaDraft.constraintsText),
  });
}

function reconnectGateway() {
  post("gateway.reconnect");
}

function resetPetPosition() {
  post("settings.resetPetPosition");
}

function importModel() {
  post("settings.importModel");
}

function handlePointerMove(event) {
  if (isPetMode.value || !runtime || !event.currentTarget) {
    return;
  }

  const rect = event.currentTarget.getBoundingClientRect();
  const x = (event.clientX - rect.left - rect.width / 2) / rect.width;
  const y = (event.clientY - rect.top - rect.height / 2) / rect.height;
  runtime.updatePointerFocus(x, y);
}

function handlePointerLeave() {
  runtime?.clearPointerFocus();
}

function handleTapCharacter() {
  void runtime?.tapBody();
}

onMounted(async () => {
  await nextTick();
  if (live2dHost.value && modelFallback.value) {
    runtime = new Live2DStageRuntime({
      host: live2dHost.value,
      fallback: modelFallback.value,
      isPetMode: isPetMode.value,
    });
    void syncLive2D();
  }
});

defineExpose({ receive });
</script>

<template>
  <div class="stage-shell" :class="{ 'is-pet': isPetMode }" :style="themeStyle">
    <template v-if="!isPetMode">
      <section class="scene-column">
        <div class="scene-backdrop">
          <div class="backdrop-halo halo-a"></div>
          <div class="backdrop-halo halo-b"></div>
          <div class="backdrop-grid"></div>
        </div>

        <header class="scene-meta">
          <div class="meta-pill">
            <span class="meta-pill__dot"></span>
            {{ displayPack?.interactionProfile?.personaLabel || "AIRI 角色" }}
          </div>
        </header>

        <div
          class="scene-surface"
          @pointermove="handlePointerMove"
          @pointerleave="handlePointerLeave"
          @click="handleTapCharacter"
        >
          <div class="scene-aura"></div>
          <div class="scene-frame">
            <div class="live2d-host" ref="live2dHost"></div>
            <div class="model-fallback" ref="modelFallback">正在加载 AIRI Live2D…</div>
          </div>
          <div v-if="hasSubtitle" class="subtitle-bubble">
            <div class="subtitle-prefix">{{ displayPack?.dialogueProfile?.subtitlePrefix || "AIRI" }}</div>
            <div class="subtitle-text">{{ subtitleText }}</div>
          </div>
        </div>
      </section>

      <aside class="chat-column">
        <header class="chat-header">
          <div class="chat-header__copy">
            <p class="eyebrow">KINKOCLAW 前台</p>
            <h1>{{ displayPack?.displayName || "AIRI" }}</h1>
          </div>
          <div class="header-actions">
            <button
              type="button"
              class="icon-button"
              :aria-expanded="state.settingsOpen"
              aria-label="打开设置"
              @click="setSettingsOpen(!state.settingsOpen)"
            >
              <span class="gear-icon">⚙</span>
            </button>
          </div>
        </header>

        <section class="message-list">
          <article
            v-for="message in renderedMessages"
            :key="message.id"
            class="message-card"
            :class="message.role === 'user' ? 'user' : 'assistant'"
          >
            <div class="message-card__meta">
              <span>{{ message.role === "user" ? "你" : displayPack?.dialogueProfile?.subtitlePrefix || "AIRI" }}</span>
              <span>{{ message.pending ? "发送中" : formatMessageTime(message.timestamp) }}</span>
            </div>
            <div class="message-card__text">{{ escapeText(message.text) }}</div>
          </article>
        </section>

        <form class="composer" @submit.prevent="submitMessage">
          <textarea
            id="composer-textarea"
            v-model="composerText"
            rows="3"
            placeholder="说点什么…"
            @keydown.enter.exact.prevent="submitMessage"
          />
        </form>

        <transition name="drawer">
          <section v-if="state.settingsOpen" class="settings-drawer">
            <header class="drawer-header">
              <div>
                <p class="eyebrow">设置</p>
                <h2>舞台控制</h2>
              </div>
              <button type="button" class="icon-button" aria-label="关闭设置" @click="setSettingsOpen(false)">
                <span class="close-icon">×</span>
              </button>
            </header>

            <div class="drawer-sections">
              <section class="drawer-section">
                <div class="drawer-section__header">
                  <div>
                    <p class="drawer-kicker">连接</p>
                    <h3>OpenClaw 网关</h3>
                  </div>
                  <span class="drawer-badge">{{ connectionLabel }}</span>
                </div>

                <div class="mode-switch">
                  <button
                    v-for="mode in ['local', 'sshTunnel', 'directWss']"
                    :key="mode"
                    type="button"
                    class="mode-pill"
                    :class="{ active: connectionDraft.mode === mode }"
                    @click="connectionDraft.mode = mode"
                  >
                    {{ mode === "local" ? "本地" : mode === "sshTunnel" ? "SSH 隧道" : "直连 wss" }}
                  </button>
                </div>

                <label class="field" v-if="connectionDraft.mode === 'local'">
                  <span>本地端口</span>
                  <input v-model.number="connectionDraft.localPort" type="number" min="1" max="65535" />
                </label>

                <template v-if="connectionDraft.mode === 'sshTunnel'">
                  <label class="field">
                    <span>SSH 目标</span>
                    <input v-model="connectionDraft.sshTarget" placeholder="user@gateway-host:22" />
                  </label>
                  <label class="field">
                    <span>私钥路径</span>
                    <input v-model="connectionDraft.sshIdentityPath" placeholder="可选的 SSH 私钥路径" />
                  </label>
                </template>

                <template v-if="connectionDraft.mode === 'directWss'">
                  <label class="field">
                    <span>网关地址</span>
                    <input v-model="connectionDraft.directGatewayURL" placeholder="wss://gateway.example.com" />
                  </label>
                </template>

                <label class="field">
                  <span>令牌引用</span>
                  <input v-model="connectionDraft.gatewayAuthTokenRef" placeholder="default" />
                </label>
                <label class="field">
                  <span>网关令牌</span>
                  <input v-model="connectionDraft.gatewayAuthToken" placeholder="可选的鉴权令牌" />
                </label>

                <p class="connection-feedback">
                  {{ drawerConnectionFeedback }}
                </p>

                <div class="drawer-actions">
                  <button type="button" class="secondary-button" @click="reconnectGateway">重新连接</button>
                  <button type="button" class="primary-button" @click="saveConnection">保存并连接</button>
                </div>
              </section>

              <section class="drawer-section">
                <div class="drawer-section__header">
                  <div>
                    <p class="drawer-kicker">形象</p>
                    <h3>Live2D 模型与主题</h3>
                  </div>
                </div>

                <div class="drawer-actions drawer-actions--leading">
                  <button type="button" class="secondary-button" @click="importModel">导入 Live2D 模型</button>
                </div>

                <p class="subsection-label">模型</p>
                <div class="model-grid">
                  <button
                    v-for="pack in state.availablePacks"
                    :key="pack.id"
                    type="button"
                    class="model-card"
                    :class="{ active: characterDraft.selectedLive2DModelId === pack.id }"
                    @click="characterDraft.selectedLive2DModelId = pack.id"
                  >
                    <span v-if="pack.previewImage" class="model-card__avatar">
                      <img :src="resolveAssetURL(pack.previewImage)" :alt="`${pack.displayName} 头像`" loading="lazy" />
                    </span>
                    <span v-else class="model-card__swatch" :style="{ background: pack.accentHex }"></span>
                    <span class="model-card__content">
                      <span class="model-card__title">{{ pack.displayName }}</span>
                      <span class="model-card__meta">{{ pack.sourceLabel }} · {{ pack.interactionProfile.personaLabel }}</span>
                    </span>
                  </button>
                </div>

                <p class="subsection-label">主题包</p>
                <div class="theme-grid">
                  <button
                    v-for="theme in state.availableThemes"
                    :key="theme.id"
                    type="button"
                    class="theme-card"
                    :class="{ active: characterDraft.selectedThemeId === theme.id }"
                    @click="characterDraft.selectedThemeId = theme.id"
                  >
                    <span class="theme-card__swatch" :style="{ background: theme.accentHex }"></span>
                    <span class="theme-card__content">
                      <span class="theme-card__title">{{ theme.displayName }}</span>
                      <span class="theme-card__meta">{{ theme.subtitle }}</span>
                    </span>
                  </button>
                </div>

                <label class="field slider">
                  <span>舞台缩放</span>
                  <input v-model.number="characterDraft.sceneModelScale" type="range" min="0.72" max="1.4" step="0.01" />
                  <strong>{{ characterDraft.sceneModelScale.toFixed(2) }}</strong>
                </label>

                <label class="field slider">
                  <span>水平偏移</span>
                  <input v-model.number="characterDraft.sceneModelOffsetX" type="range" min="-0.22" max="0.22" step="0.005" />
                  <strong>{{ characterDraft.sceneModelOffsetX.toFixed(3) }}</strong>
                </label>

                <label class="field slider">
                  <span>垂直偏移</span>
                  <input v-model.number="characterDraft.sceneModelOffsetY" type="range" min="-0.22" max="0.22" step="0.005" />
                  <strong>{{ characterDraft.sceneModelOffsetY.toFixed(3) }}</strong>
                </label>

                <div class="drawer-actions">
                  <button type="button" class="secondary-button" @click="resetPetPosition">重置桌宠位置</button>
                  <button type="button" class="primary-button" @click="saveCharacter">应用主题与形象</button>
                </div>
              </section>

              <section class="drawer-section">
                <div class="drawer-section__header">
                  <div>
                    <p class="drawer-kicker">人设记忆卡</p>
                    <h3>本地回复塑形</h3>
                  </div>
                </div>

                <label class="field">
                  <span>角色身份</span>
                  <textarea v-model="personaDraft.characterIdentity" rows="3" placeholder="这个角色是谁。" />
                </label>
                <label class="field">
                  <span>说话风格</span>
                  <textarea v-model="personaDraft.speakingStyle" rows="3" placeholder="希望角色怎么说话。" />
                </label>
                <label class="field">
                  <span>与用户关系</span>
                  <textarea v-model="personaDraft.relationshipToUser" rows="3" placeholder="角色如何看待用户。" />
                </label>
                <label class="field">
                  <span>长期记忆</span>
                  <textarea v-model="personaDraft.longTermMemoriesText" rows="4" placeholder="每行一条长期记忆。" />
                </label>
                <label class="field">
                  <span>约束</span>
                  <textarea v-model="personaDraft.constraintsText" rows="4" placeholder="每行一条约束。" />
                </label>

                <div class="drawer-actions">
                  <button type="button" class="primary-button" @click="savePersona">保存记忆卡</button>
                </div>
              </section>
            </div>
          </section>
        </transition>
      </aside>

      <transition name="toast-fade">
        <div v-if="toastVisible" class="toast">{{ toastMessage }}</div>
      </transition>
    </template>

    <template v-else>
      <section class="pet-shell" @click="handleTapCharacter">
        <div class="pet-aura"></div>
        <div class="pet-host" ref="live2dHost"></div>
        <div class="model-fallback pet" ref="modelFallback">正在加载 AIRI Live2D…</div>
      </section>
    </template>
  </div>
</template>
