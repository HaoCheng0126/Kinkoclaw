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

ZipLoader.zipReader = (data) => JSZip.loadAsync(data);

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

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function pickMotionToken(tokens) {
  if (!Array.isArray(tokens) || tokens.length === 0) {
    return null;
  }
  return tokens[Math.floor(Math.random() * tokens.length)];
}

function resolveModelURL(rawPath) {
  const safePath = rawPath?.trim() || "models/chitose/chitose.model3.json";
  return new URL(safePath, window.location.href).href;
}

export class Live2DStageRuntime {
  constructor({ host, fallback, isPetMode }) {
    this.host = host;
    this.fallback = fallback;
    this.isPetMode = isPetMode;
    this.app = null;
    this.model = null;
    this.modelURL = null;
    this.pack = null;
    this.sceneFrame = { scale: 1, offsetX: 0, offsetY: 0 };
    this.presenceState = "disconnected";
    this.motionPresence = null;
    this.activeExpression = null;
    this.mouthTarget = 0;
    this.mouthCurrent = 0;
    this.frameHandle = 0;
    this.resizeObserver = null;
    this.lastMotionAt = 0;
    this.lastPointerAt = 0;
    this.pointerFocusX = 0;
    this.pointerFocusY = 0;
    this.naturalModelBounds = null;
    this.loadGeneration = 0;
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
    if (!this.app) {
      return;
    }

    try {
      if (this.model) {
        this.app.stage.removeChild(this.model);
        this.model.destroy();
      }

      for (const child of this.app.stage.removeChildren()) {
        if (child !== this.model && typeof child.destroy === "function") {
          child.destroy();
        }
      }
    } catch (error) {
      console.warn("Failed to destroy old Live2D model", error);
    }

    this.model = null;
    this.motionPresence = null;
    this.activeExpression = null;
    this.naturalModelBounds = null;
  }

  async sync({ pack, presenceState, sceneFrame, mouthTarget }) {
    if (!pack?.model?.modelPath) {
      return;
    }

    const nextURL = resolveModelURL(pack.model.modelPath);
    const needsReload = this.modelURL !== nextURL || !this.model;
    this.pack = pack;
    this.sceneFrame = sceneFrame ?? { scale: 1, offsetX: 0, offsetY: 0 };

    await this.init();

    if (needsReload) {
      this.showFallback("正在加载 Live2D…");
      this.destroyModel();
      this.modelURL = nextURL;
      const generation = ++this.loadGeneration;

      const model = new Live2DModel();
      await Live2DFactory.setupLive2DModel(model, nextURL, { autoInteract: false });
      if (generation !== this.loadGeneration) {
        model.destroy();
        return;
      }

      for (const child of this.app.stage.removeChildren()) {
        if (typeof child.destroy === "function") {
          child.destroy();
        }
      }
      this.model = model;
      this.app.stage.addChild(model);
      const bounds = model.getLocalBounds?.() ?? { x: 0, y: 0, width: model.width, height: model.height };
      this.naturalModelBounds = {
        x: Number(bounds.x) || 0,
        y: Number(bounds.y) || 0,
        width: Math.max(1, Number(bounds.width) || model.width || 1),
        height: Math.max(1, Number(bounds.height) || model.height || 1),
      };
      this.hideFallback();
    }

    this.fitModel();
    this.setPresenceState(presenceState);
    this.setMouthTarget(mouthTarget);
    await this.applyExpressionForPresence(presenceState);
  }

  fitModel() {
    if (!this.model || !this.app) {
      return;
    }

    const width = this.host.clientWidth || this.app.renderer.width;
    const height = this.host.clientHeight || this.app.renderer.height;
    const bounds = this.naturalModelBounds ?? {
      x: 0,
      y: 0,
      width: Math.max(1, this.model.width),
      height: Math.max(1, this.model.height),
    };
    const modelWidth = Math.max(1, bounds.width);
    const modelHeight = Math.max(1, bounds.height);
    const visibleCenterX = bounds.x + bounds.width / 2;
    const visibleBottomY = bounds.y + bounds.height;
    const defaultFrame = this.pack?.defaultSceneFrame ?? { scale: 1, offsetX: 0, offsetY: 0 };
    const userFrame = this.sceneFrame ?? { scale: 1, offsetX: 0, offsetY: 0 };

    if (this.isPetMode) {
      const scale = Math.min((width * 0.82) / modelWidth, (height * 0.9) / modelHeight);
      this.model.scale.set(scale);
      this.model.x = width * 0.5 - visibleCenterX * scale;
      this.model.y = height * 0.985 - visibleBottomY * scale;
      return;
    }

    const frameScale = clamp((defaultFrame.scale ?? 1) * (userFrame.scale ?? 1), 0.72, 1.42);
    const offsetX = clamp((defaultFrame.offsetX ?? 0) + (userFrame.offsetX ?? 0), -0.24, 0.24);
    const offsetY = clamp((defaultFrame.offsetY ?? 0) + (userFrame.offsetY ?? 0), -0.24, 0.24);
    const scale = Math.min((width * 0.9) / modelWidth, (height * 0.95) / modelHeight) * frameScale;

    this.model.scale.set(scale);
    this.model.x = width * (0.5 + offsetX) - visibleCenterX * scale;
    this.model.y = height * (0.985 + offsetY) - visibleBottomY * scale;
  }

  updatePointerFocus(x, y) {
    if (!this.model?.focus || this.isPetMode) {
      return;
    }

    this.lastPointerAt = performance.now();
    const strength = clamp(this.pack?.interactionProfile?.pointerFollowStrength ?? 0.24, 0, 0.35);
    this.pointerFocusX = clamp(x * strength, -0.28, 0.28);
    this.pointerFocusY = clamp(y * strength * 0.82, -0.24, 0.24);
  }

  clearPointerFocus() {
    this.lastPointerAt = 0;
    this.pointerFocusX = 0;
    this.pointerFocusY = 0;
    if (!this.isPetMode && this.model?.focus) {
      this.model.focus(0, 0);
    }
  }

  setMouthTarget(value) {
    this.mouthTarget = clamp(value ?? 0, 0, 0.94);
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

  async applyExpressionForPresence(presence) {
    const expressionID = this.pack?.model?.expressions?.[presence] ?? this.pack?.model?.expressions?.idle;
    if (!expressionID || !this.model || this.activeExpression === expressionID) {
      return;
    }

    try {
      await this.model.expression(expressionID);
      this.activeExpression = expressionID;
    } catch (error) {
      console.warn(`Failed to apply expression ${expressionID}`, error);
    }
  }

  async playPresenceMotion(presence, allowRepeat = false) {
    if (!this.model || !this.pack?.model?.motions) {
      return;
    }

    const now = Date.now();
    if (!allowRepeat && this.motionPresence === presence && now - this.lastMotionAt < 1200) {
      return;
    }

    const token = pickMotionToken(this.pack.model.motions[presence] ?? this.pack.model.motions.idle ?? []);
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
      const smoothing = clamp(this.pack?.animationProfile?.mouthSmoothing ?? 0.78, 0.12, 0.92);
      this.mouthCurrent += (this.mouthTarget - this.mouthCurrent) * (1 - smoothing * 0.72);
      coreModel.setParameterValueById("ParamMouthOpenY", this.mouthCurrent);
    }

    if (this.model?.focus && !this.isPetMode) {
      const now = performance.now();
      if (this.lastPointerAt && now - this.lastPointerAt < 2400) {
        this.model.focus(this.pointerFocusX, this.pointerFocusY);
      } else {
        const speed = this.pack?.animationProfile?.focusSwaySpeed ?? 0.8;
        this.model.focus(Math.sin(now * 0.00045 * speed) * 0.042, Math.cos(now * 0.00031 * speed) * 0.028);
      }
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
