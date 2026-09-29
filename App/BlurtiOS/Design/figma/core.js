// The Blurt Keyboard Figma file, built from the tokens. core.js: names and helpers every module needs. Plain Plugin API, so
// the same functions run two ways (README.md): pasted into a use_figma call
// behind tokens.js with `return await buildFoundations();`, or bundled by
// scripts/design-sync.sh into a development plugin (plugin.js dispatches).
// Everything is idempotent — find by name before create — and every builder
// returns the ids and counts it touched. No `figma.notify`, no console output.
/* global figma, TOKEN_LINES, GROUPS */

// ---------------------------------------------------------------------------
// Names

const PAGES = { foundations: "01 Foundations", components: "02 Components", layouts: "03 Layouts" };
const FONT = { family: "SF Pro", regular: "Regular", medium: "Medium", semibold: "Semibold" };
const DEVICE_WIDTH = 402; // iPhone 18 Pro, the simulator this repo captures on
const DESIGN_THEME = "ink";
const THEMES = ["system-light", "system-dark", "ink", "paper", "lavender", "mint", "midnight", "sunset"];
const ROLES = ["surface", "key", "key-modifier", "legend", "signal", "popup"];
const STATES = ["off", "start", "idle", "connecting", "recording", "processing", "pasted", "copied", "error", "term"];

// ---------------------------------------------------------------------------
// The tokens. buildFoundations carries them (tokens.js, one line per variable);
// every later builder reads them back from the file's variables, so a call
// stays under use_figma's 50,000-character cap.

function parseTokenLines(text) {
  const collections = {};
  const gradients = {};
  for (const line of text.split("\n")) {
    if (!line) continue;
    const parts = line.split("|");
    if (parts[0] === "GRADIENT") {
      const [, name, start, end, stops, use] = parts;
      gradients[name] = {
        start,
        end,
        use,
        stops: stops.split(",").map((s) => {
          const [value, location] = s.split("@");
          return { value, location: Number(location) };
        }),
      };
      continue;
    }
    const [collection, name, type, raw, alias, scopes, codeSyntax, use] = parts;
    if (!collections[collection]) collections[collection] = { mode: "Value", variables: [] };
    collections[collection].variables.push({
      name,
      type,
      value: type === "FLOAT" ? Number(raw) : raw,
      alias: alias || null,
      scopes: scopes ? scopes.split(",") : [],
      codeSyntax,
      use,
    });
  }
  return { collections, gradients, groups: typeof GROUPS !== "undefined" ? GROUPS : Object.keys(collections) };
}

let TOKENS = typeof TOKEN_LINES !== "undefined" ? parseTokenLines(TOKEN_LINES) : null;
const GRADIENT_STYLES = {};

function rgbToHex(c) {
  return "#" + [c.r, c.g, c.b].map((x) => Math.round(x * 255).toString(16).padStart(2, "0").toUpperCase()).join("");
}

/** Loads TOKENS from the file's variables and gradient paint styles when the call carried none. */
async function ensureTokens() {
  const styles = await figma.getLocalPaintStylesAsync();
  for (const s of styles) if (s.name.startsWith("Gradient/")) GRADIENT_STYLES[s.name.slice(9)] = s.paints[0];
  if (TOKENS) return TOKENS;
  const map = await variableMap();
  if (map.size === 0) throw new Error("the file has no variables yet — run buildFoundations first");
  const collectionsById = new Map((await figma.variables.getLocalVariableCollectionsAsync()).map((c) => [c.id, c]));
  const byId = new Map([...map.values()].map((v) => [v.id, v]));
  function resolveValue(v, depth) {
    const c = collectionsById.get(v.variableCollectionId);
    const raw = v.valuesByMode[c.modes[0].modeId];
    if (raw && typeof raw === "object" && raw.type === "VARIABLE_ALIAS") {
      const target = byId.get(raw.id);
      return target && depth < 8 ? resolveValue(target, depth + 1) : null;
    }
    return raw;
  }
  const collections = {};
  for (const [key, v] of map) {
    const i = key.indexOf(":");
    const collection = key.slice(0, i);
    const name = key.slice(i + 1);
    const raw = resolveValue(v, 0);
    const value = v.resolvedType === "COLOR" && raw ? rgbToHex(raw) : raw;
    if (!collections[collection]) collections[collection] = { mode: "Value", variables: [] };
    collections[collection].variables.push({ name, type: v.resolvedType, value, alias: null, scopes: v.scopes, use: v.description });
  }
  TOKENS = { collections, gradients: {}, groups: Object.keys(collections) };
  return TOKENS;
}

// ---------------------------------------------------------------------------
// Helpers

function hexToRGB(hex) {
  const n = parseInt(hex.slice(1), 16);
  return { r: ((n >> 16) & 255) / 255, g: ((n >> 8) & 255) / 255, b: (n & 255) / 255 };
}

function token(collection, name) {
  const entry = TOKENS.collections[collection].variables.find((v) => v.name === name);
  if (!entry) throw new Error(`no token ${collection}:${name}`);
  return entry;
}

function metric(name) {
  return token("Metrics", name).value;
}

async function getPage(name) {
  let page = figma.root.children.find((p) => p.name === name);
  if (!page) {
    page = figma.createPage();
    page.name = name;
  }
  await figma.setCurrentPageAsync(page);
  return page;
}

function getSection(page, name, x, y) {
  let section = page.children.find((n) => n.type === "SECTION" && n.name === name);
  if (!section) {
    section = figma.createSection();
    section.name = name;
    section.x = x;
    section.y = y;
    page.appendChild(section);
  }
  return section;
}

/** Every local variable, keyed "Collection:name". */
async function variableMap() {
  const collections = await figma.variables.getLocalVariableCollectionsAsync();
  const byId = new Map(collections.map((c) => [c.id, c]));
  const map = new Map();
  for (const v of await figma.variables.getLocalVariablesAsync()) {
    const collection = byId.get(v.variableCollectionId);
    if (collection) map.set(`${collection.name}:${v.name}`, v);
  }
  return map;
}

let VARS = null;
async function vars() {
  if (!VARS) VARS = await variableMap();
  return VARS;
}

async function variable(ref) {
  const v = (await vars()).get(ref);
  if (!v) throw new Error(`variable ${ref} is not in the file — run buildFoundations first`);
  return v;
}

/** A solid paint bound to a colour variable. */
async function paint(ref) {
  const v = await variable(ref);
  return figma.variables.setBoundVariableForPaint({ type: "SOLID", color: { r: 0, g: 0, b: 0 } }, "color", v);
}

async function bind(node, field, ref) {
  node.setBoundVariable(field, await variable(ref));
}

async function bindRadius(node, ref) {
  for (const corner of ["topLeftRadius", "topRightRadius", "bottomLeftRadius", "bottomRightRadius"]) {
    await bind(node, corner, ref);
  }
}

async function loadFonts() {
  const available = await figma.listAvailableFontsAsync();
  const families = new Set(available.map((f) => f.fontName.family));
  if (!families.has(FONT.family)) {
    throw new Error(`${FONT.family} is not available in this file; install SF Pro from developer.apple.com/fonts`);
  }
  for (const style of [FONT.regular, FONT.medium, FONT.semibold]) {
    await figma.loadFontAsync({ family: FONT.family, style });
  }
}

/** An SF Symbol as a character where the runtime can (the MCP one), else a stand-in. */
function symbolChar(name, fallback) {
  try {
    if (figma.util && typeof figma.util.getSfSymbolCharacter === "function") {
      return figma.util.getSfSymbolCharacter(name);
    }
  } catch (_) {
    // fall through to the stand-in
  }
  return fallback;
}

async function textNode(characters, { size, weight = FONT.regular, fillRef, styleId } = {}) {
  const t = figma.createText();
  t.fontName = { family: FONT.family, style: weight };
  t.characters = characters;
  if (size) t.fontSize = size;
  if (styleId) t.textStyleId = styleId;
  if (fillRef) t.fills = [await paint(fillRef)];
  t.textAutoResize = "WIDTH_AND_HEIGHT";
  return t;
}

function autoLayout(direction, props = {}) {
  const frame = figma.createFrame();
  frame.layoutMode = direction;
  frame.primaryAxisSizingMode = "AUTO";
  frame.counterAxisSizingMode = "AUTO";
  frame.fills = [];
  frame.clipsContent = false;
  Object.assign(frame, props);
  return frame;
}

function gradientPaint(gradientName) {
  const g = TOKENS && TOKENS.gradients[gradientName];
  if (!g) {
    if (GRADIENT_STYLES[gradientName]) return GRADIENT_STYLES[gradientName];
    throw new Error(`no gradient ${gradientName}: run buildFoundations (it saves Gradient/* paint styles)`);
  }
  const transforms = {
    "bottom>top": [
      [0, -1, 1],
      [1, 0, 0],
    ],
    "topLeading>bottomTrailing": [
      [0.5, 0.5, 0],
      [-0.5, 0.5, 0.5],
    ],
  };
  return {
    type: "GRADIENT_LINEAR",
    gradientTransform: transforms[`${g.start}>${g.end}`] || transforms["bottom>top"],
    gradientStops: g.stops.map((s) => ({ position: s.location, color: { ...hexToRGB(s.value), a: 1 } })),
  };
}
