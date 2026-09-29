// The Blurt Keyboard Figma file, built from the tokens. Plain Plugin API, so
// the same functions run two ways (README.md): pasted into a use_figma call
// behind tokens.js with `return await buildFoundations();`, or bundled by
// scripts/design-sync.sh into a development plugin (plugin.js dispatches).
// Everything is idempotent — find by name before create — and every builder
// returns the ids and counts it touched. No `figma.notify`, no console output.
/* global figma, TOKENS */

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
  const g = TOKENS.gradients[gradientName];
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

// ---------------------------------------------------------------------------
// Foundations: variables, styles, specimens

async function buildFoundations() {
  const page = await getPage(PAGES.foundations);
  const existingCollections = await figma.variables.getLocalVariableCollectionsAsync();
  const created = { collections: 0, variables: 0, aliases: 0, textStyles: 0, effectStyles: 0 };
  const collections = {};
  for (const name of TOKENS.groups) {
    let c = existingCollections.find((x) => x.name === name);
    if (!c) {
      c = figma.variables.createVariableCollection(name);
      created.collections += 1;
    }
    c.renameMode(c.modes[0].modeId, TOKENS.collections[name].mode);
    collections[name] = c;
  }
  VARS = await variableMap();
  // Concrete values first, aliases second, so a target always exists.
  for (const pass of ["values", "aliases"]) {
    for (const name of TOKENS.groups) {
      const c = collections[name];
      const modeId = c.modes[0].modeId;
      for (const spec of TOKENS.collections[name].variables) {
        if ((pass === "aliases") !== Boolean(spec.alias)) continue;
        const key = `${name}:${spec.name}`;
        let v = VARS.get(key);
        if (!v) {
          v = figma.variables.createVariable(spec.name, c, spec.type);
          VARS.set(key, v);
          created.variables += 1;
        }
        if (spec.alias) {
          const target = VARS.get(spec.alias);
          if (!target) throw new Error(`${key} aliases ${spec.alias}, which is missing`);
          v.setValueForMode(modeId, figma.variables.createVariableAlias(target));
          created.aliases += 1;
        } else if (spec.type === "COLOR") {
          v.setValueForMode(modeId, { ...hexToRGB(spec.value), a: 1 });
        } else {
          v.setValueForMode(modeId, spec.value);
        }
        v.scopes = spec.scopes;
        v.description = spec.use || "";
        v.setVariableCodeSyntax("iOS", spec.codeSyntax);
      }
    }
  }

  await loadFonts();
  const sizes = Object.fromEntries(
    TOKENS.collections.Typography.variables.filter((v) => v.name.startsWith("size/")).map((v) => [v.name.slice(5), v.value])
  );
  const weights = Object.fromEntries(
    TOKENS.collections.Typography.variables.filter((v) => v.name.startsWith("weight/")).map((v) => [v.name.slice(7), v.value])
  );
  const weightStyle = { regular: FONT.regular, medium: FONT.medium, semibold: FONT.semibold };
  const textStyleSpecs = [
    ["Key/Letter", sizes.letter, weights.letter],
    ["Key/Legend", sizes.legend, weights.legend],
    ["Key/Popup", sizes.popup, weights.popup],
    ["Term/Text", sizes.term, weights.term],
    ["Glyph", sizes.glyph, weights.glyph],
  ];
  const textStyles = await figma.getLocalTextStylesAsync();
  for (const [name, size, weight] of textStyleSpecs) {
    let s = textStyles.find((x) => x.name === name);
    if (!s) {
      s = figma.createTextStyle();
      s.name = name;
      created.textStyles += 1;
    }
    s.fontName = { family: FONT.family, style: weightStyle[weight] };
    s.fontSize = size;
  }
  const effectStyles = await figma.getLocalEffectStylesAsync();
  let shadow = effectStyles.find((x) => x.name === "Shadow/Popup");
  if (!shadow) {
    shadow = figma.createEffectStyle();
    shadow.name = "Shadow/Popup";
    created.effectStyles += 1;
  }
  // Figma's blur is about twice SwiftUI's shadow radius; the generator's
  // DESIGN.md note says the same, so the two stay one number apart on purpose.
  shadow.effects = [
    {
      type: "DROP_SHADOW",
      color: { r: 0, g: 0, b: 0, a: metric("opacity/popup-shadow") },
      offset: { x: 0, y: metric("popup/shadow-y") },
      radius: metric("popup/shadow-radius") * 2,
      spread: 0,
      visible: true,
      blendMode: "NORMAL",
    },
  ];

  // Specimens: swatches for every colour, a line per number, all bound.
  const ids = [];
  const colours = getSection(page, "Colour", 0, 0);
  const grid = autoLayout("VERTICAL", { name: "Swatches", itemSpacing: 8 });
  for (const name of ["Brand", "Themes", "Keyboard"]) {
    const row = autoLayout("VERTICAL", { name, itemSpacing: 4 });
    row.appendChild(await textNode(name, { size: 14, weight: FONT.medium, fillRef: "Brand:ink" }));
    const wrap = autoLayout("HORIZONTAL", { name: `${name} swatches`, itemSpacing: 8 });
    wrap.layoutWrap = "WRAP";
    wrap.counterAxisSpacing = 8;
    wrap.resize(1200, 10);
    wrap.primaryAxisSizingMode = "FIXED";
    for (const spec of TOKENS.collections[name].variables) {
      const cell = autoLayout("VERTICAL", { name: spec.name, itemSpacing: 2 });
      const swatch = figma.createRectangle();
      swatch.resize(64, 40);
      swatch.cornerRadius = 4;
      swatch.fills = [await paint(`${name}:${spec.name}`)];
      cell.appendChild(swatch);
      cell.appendChild(await textNode(spec.name, { size: 9, fillRef: "Brand:ink" }));
      cell.appendChild(await textNode(spec.value, { size: 9, fillRef: "Brand:ink" }));
      wrap.appendChild(cell);
    }
    row.appendChild(wrap);
    grid.appendChild(row);
  }
  const oldGrid = colours.children.find((n) => n.name === "Swatches");
  if (oldGrid) oldGrid.remove();
  colours.appendChild(grid);
  colours.resizeWithoutConstraints(grid.width + 80, grid.height + 80);
  grid.x = 40;
  grid.y = 40;
  ids.push(grid.id);

  const numbers = getSection(page, "Numbers", 0, colours.height + 80);
  const list = autoLayout("VERTICAL", { name: "Tokens", itemSpacing: 2 });
  for (const name of ["Metrics", "Typography", "Motion"]) {
    list.appendChild(await textNode(name, { size: 14, weight: FONT.medium, fillRef: "Brand:ink" }));
    for (const spec of TOKENS.collections[name].variables) {
      list.appendChild(
        await textNode(`${spec.name} = ${spec.value}  ·  ${spec.codeSyntax}${spec.use ? "  —  " + spec.use : ""}`, {
          size: 10,
          fillRef: "Brand:ink",
        })
      );
    }
  }
  const oldList = numbers.children.find((n) => n.name === "Tokens");
  if (oldList) oldList.remove();
  numbers.appendChild(list);
  numbers.resizeWithoutConstraints(list.width + 80, list.height + 80);
  list.x = 40;
  list.y = 40;
  ids.push(list.id);

  const recipe = getSection(page, "Orb recipe", colours.width + 80, 0);
  const note = await textNode(
    [
      "The orb is the one thing Figma does not draw. It is a 3 × 3 MeshGradient whose edge midpoints and centre",
      "drift on slow sines (further with the voice), under a soft upper-left light (opacity/orb-light,",
      "orb/light-x, orb/light-y, orb/light-radius) and film grain (opacity/grain; a seeded scatter of 1 pt dots,",
      "one per 26 pt²). The words landing pours cobolt in from the centre (drop, drop-rise, drop-hold) with six",
      "four-point sparkles. Orb/Disc's fills are stills the app renders (-BlurtOrb <size> <mood>); the",
      "parameters above are the variables. Source: App/BlurtiOS/BlurtKeyboard/Sources/PrismOrb.swift.",
    ].join("\n"),
    { size: 11, fillRef: "Brand:ink" }
  );
  note.textAutoResize = "HEIGHT";
  note.resize(720, 10);
  const oldNote = recipe.children.find((n) => n.type === "TEXT");
  if (oldNote) oldNote.remove();
  recipe.appendChild(note);
  recipe.resizeWithoutConstraints(800, note.height + 80);
  note.x = 40;
  note.y = 40;

  return { page: page.id, created, specimenIds: ids, variables: VARS.size };
}

// ---------------------------------------------------------------------------
// Export: the variables back out as tokens.json's groups

async function exportTokens() {
  const collections = await figma.variables.getLocalVariableCollectionsAsync();
  const byId = new Map(collections.map((c) => [c.id, c]));
  const all = await figma.variables.getLocalVariablesAsync();
  const byVarId = new Map(all.map((v) => [v.id, v]));
  const groupOf = { Brand: "brand", Themes: "themes", Keyboard: "keyboard", Metrics: "metrics", Typography: "type", Motion: "motion" };
  const out = {};
  for (const v of all) {
    const c = byId.get(v.variableCollectionId);
    const group = c && groupOf[c.name];
    if (!group) continue;
    const modeId = c.modes[0].modeId;
    let raw = v.valuesByMode[modeId];
    let value;
    if (raw && typeof raw === "object" && raw.type === "VARIABLE_ALIAS") {
      const target = byVarId.get(raw.id);
      const tc = byId.get(target.variableCollectionId);
      value = `{${groupOf[tc.name]}.${target.name}}`;
    } else if (raw && typeof raw === "object" && "r" in raw) {
      const hex = [raw.r, raw.g, raw.b].map((x) => Math.round(x * 255).toString(16).padStart(2, "0")).join("");
      value = `#${hex.toUpperCase()}`;
    } else {
      value = raw;
    }
    out[group] = out[group] || {};
    out[group][v.name] = v.description ? { value, use: v.description } : { value };
  }
  return { tokens: out, note: "merge into App/BlurtiOS/Design/tokens.json (keep gradients and figma), then scripts/design-sync.sh" };
}

/** The absolute bounds of every named node under the layout frames, in points. */
async function exportBounds() {
  const page = await getPage(PAGES.layouts);
  const frames = page.findAll((n) => n.type === "FRAME" && /^(panel|slimBar|full)\//.test(n.name));
  const bounds = {};
  for (const frame of frames) {
    const origin = frame.absoluteBoundingBox;
    bounds[frame.name] = {};
    for (const node of frame.findAll((n) => n.name && n.absoluteBoundingBox)) {
      const b = node.absoluteBoundingBox;
      bounds[frame.name][node.name] = {
        x: +(b.x - origin.x).toFixed(2),
        y: +(b.y - origin.y).toFixed(2),
        w: +b.width.toFixed(2),
        h: +b.height.toFixed(2),
        type: node.type,
      };
    }
  }
  return { frames: frames.length, bounds };
}

// ---------------------------------------------------------------------------
// Components (02 Components). Every fill, stroke, radius and gap is bound to a
// variable; the orb's disc is the one image fill (see buildOrbDisc).

const SIZES = { Bar: "orb/bar", Panel: "orb/panel", Home: "orb/home" };
const WAVES = {
  Bar: ["wave/bar-width", "wave/bar-height"],
  Panel: ["wave/panel-width", "wave/panel-height"],
  Home: ["wave/home-width", "wave/home-height"],
};

async function findComponentSet(page, name) {
  return page.findOne((n) => n.type === "COMPONENT_SET" && n.name === name);
}

async function findComponent(page, name) {
  return page.findOne((n) => n.type === "COMPONENT" && n.name === name && n.parent.type !== "COMPONENT_SET");
}

async function textStyleId(name) {
  const s = (await figma.getLocalTextStylesAsync()).find((x) => x.name === name);
  if (!s) throw new Error(`text style ${name} missing — run buildFoundations first`);
  return s.id;
}

async function effectStyleId(name) {
  const s = (await figma.getLocalEffectStylesAsync()).find((x) => x.name === name);
  if (!s) throw new Error(`effect style ${name} missing — run buildFoundations first`);
  return s.id;
}

/** Replaces a component set (or lone component) of this name, keeping its position. */
function replaceNamed(page, name, node) {
  const old = page.findOne((n) => (n.type === "COMPONENT_SET" || n.type === "COMPONENT") && n.name === name);
  if (old) {
    node.x = old.x;
    node.y = old.y;
    old.remove();
  }
}

/** Lays the variants of a set out in a row and names the set. */
function finishSet(page, name, variants, x, y) {
  const set = figma.combineAsVariants(variants, page);
  set.name = name;
  set.layoutMode = "HORIZONTAL";
  set.itemSpacing = 24;
  set.paddingLeft = set.paddingRight = set.paddingTop = set.paddingBottom = 24;
  set.primaryAxisSizingMode = "AUTO";
  set.counterAxisSizingMode = "AUTO";
  set.counterAxisAlignItems = "MIN";
  set.x = x;
  set.y = y;
  return set;
}

async function keyCap(props) {
  // props: tone "Key"|"Modifier"|"Bare", pressed, label, width (fixed) or null (min width + pad)
  const c = figma.createComponent();
  c.name = `Tone=${props.tone}, State=${props.pressed ? "Pressed" : "Up"}`;
  c.layoutMode = "HORIZONTAL";
  c.primaryAxisAlignItems = "CENTER";
  c.counterAxisAlignItems = "CENTER";
  c.primaryAxisSizingMode = props.width ? "FIXED" : "AUTO";
  c.counterAxisSizingMode = "FIXED";
  c.resize(props.width || metric("key/min-width"), metric("key/height"));
  await bind(c, "height", "Metrics:key/height");
  if (props.width) await bind(c, "width", `Metrics:${props.widthRef}`);
  else {
    await bind(c, "minWidth", "Metrics:key/min-width");
    await bind(c, "paddingLeft", "Metrics:key/pad");
    await bind(c, "paddingRight", "Metrics:key/pad");
  }
  c.fills = props.tone === "Bare" ? [] : [await paint(props.tone === "Modifier" ? "Keyboard:kb/key-modifier" : "Keyboard:kb/key")];
  await bindRadius(c, "Metrics:key/radius");
  const label = await textNode(props.label, {
    styleId: await textStyleId(props.letter ? "Key/Letter" : "Key/Legend"),
    fillRef: props.tint || "Keyboard:kb/legend",
  });
  label.name = "Label";
  c.appendChild(label);
  if (props.pressed) {
    const shine = figma.createRectangle();
    shine.name = "Pressed";
    shine.fills = [{ type: "SOLID", color: { r: 1, g: 1, b: 1 } }];
    await bind(shine, "opacity", "Metrics:opacity/press-brighten");
    c.appendChild(shine);
    shine.layoutPositioning = "ABSOLUTE";
    shine.x = 0;
    shine.y = 0;
    shine.resize(c.width, c.height);
    shine.constraints = { horizontal: "STRETCH", vertical: "STRETCH" };
    await bindRadius(shine, "Metrics:key/radius");
  }
  return c;
}

async function buildKeySet(page, x, y) {
  const variants = [];
  for (const tone of ["Key", "Modifier", "Bare"]) {
    for (const pressed of [false, true]) {
      variants.push(await keyCap({ tone, pressed, label: tone === "Bare" ? "×" : "space" }));
    }
  }
  replaceNamed(page, "Key", variants[0]);
  const set = finishSet(page, "Key", variants, x, y);
  set.description = "One ordinary key: a legend on a cap in the current palette; Modifier a step darker; Bare a glyph with no cap. Flat: no drop, no edge, no gloss.";
  const labelProp = set.addComponentProperty("Label", "TEXT", "space");
  for (const v of variants) {
    const t = v.findOne((n) => n.type === "TEXT" && n.name === "Label");
    t.componentPropertyReferences = { characters: labelProp };
  }
  return set;
}

async function buildLetterKeySet(page, x, y) {
  const variants = [];
  for (const pressed of [false, true]) {
    const c = await keyCap({
      tone: "Key",
      pressed,
      label: "q",
      letter: true,
      width: metric("key/letter-width-402"),
      widthRef: "key/letter-width-402",
    });
    c.name = `State=${pressed ? "Pressed" : "Up"}`;
    if (pressed) {
      const popup = figma.createFrame();
      popup.name = "LetterPopup";
      popup.layoutMode = "HORIZONTAL";
      popup.primaryAxisAlignItems = "CENTER";
      popup.counterAxisAlignItems = "CENTER";
      popup.primaryAxisSizingMode = "FIXED";
      popup.counterAxisSizingMode = "FIXED";
      popup.resize(metric("key/letter-width-402") + metric("popup/extra-width"), metric("popup/height"));
      await bind(popup, "height", "Metrics:popup/height");
      popup.fills = [await paint("Keyboard:kb/popup")];
      await bindRadius(popup, "Metrics:popup/radius");
      popup.effectStyleId = await effectStyleId("Shadow/Popup");
      const big = await textNode("q", { styleId: await textStyleId("Key/Popup"), fillRef: "Keyboard:kb/legend" });
      big.name = "Popup label";
      popup.appendChild(big);
      c.appendChild(popup);
      popup.layoutPositioning = "ABSOLUTE";
      popup.x = -metric("popup/extra-width") / 2;
      popup.y = -metric("popup/offset");
    }
    variants.push(c);
  }
  replaceNamed(page, "LetterKey", variants[0]);
  const set = finishSet(page, "LetterKey", variants, x, y);
  set.description = "A letter key with the system keyboard's 22 pt legend and its pop-up while pressed: a 32 pt copy above the key, the one thing that floats.";
  const labelProp = set.addComponentProperty("Label", "TEXT", "q");
  for (const v of variants) {
    for (const t of v.findAll((n) => n.type === "TEXT")) t.componentPropertyReferences = { characters: labelProp };
  }
  return set;
}

async function glyphButton(name, symbol, fallback, fillRef, opacityRef) {
  const c = figma.createComponent();
  c.name = name;
  c.layoutMode = "HORIZONTAL";
  c.primaryAxisAlignItems = "CENTER";
  c.counterAxisAlignItems = "CENTER";
  c.primaryAxisSizingMode = "FIXED";
  c.counterAxisSizingMode = "FIXED";
  c.resize(metric("glyph/hit"), metric("glyph/hit"));
  await bind(c, "width", "Metrics:glyph/hit");
  await bind(c, "height", "Metrics:glyph/hit");
  const t = await textNode(symbolChar(symbol, fallback), { styleId: await textStyleId("Glyph"), fillRef });
  t.name = "Glyph";
  if (opacityRef) await bind(t, "opacity", opacityRef);
  c.appendChild(t);
  return c;
}

async function buildAddTermKey(page, x, y) {
  const off = await glyphButton("Saved=False", "plus", "+", "Keyboard:kb/legend", "Metrics:opacity/legend-muted");
  const on = await glyphButton("Saved=True", "checkmark", "✓", "Keyboard:kb/signal", null);
  replaceNamed(page, "AddTermKey", off);
  const set = finishSet(page, "AddTermKey", [off, on], x, y);
  set.description = "The small + beside the orb: a new key term. A bare glyph, quiet until needed; a check for a moment after one was saved.";
  return set;
}

async function buildCancelKey(page, x, y) {
  const c = await keyCap({ tone: "Bare", pressed: false, label: symbolChar("xmark", "×"), tint: "Keyboard:kb/cancel" });
  c.name = "CancelKey";
  c.description = "Cancel, in the panel's top-right corner while something is in flight: the orange × on no cap.";
  replaceNamed(page, "CancelKey", c);
  page.appendChild(c);
  c.x = x;
  c.y = y;
  return c;
}

async function buildTermField(page, x, y) {
  const c = figma.createComponent();
  c.name = "TermField";
  c.description = "The voice bar as a field: × to leave, what has been typed with a caret, ✓ to save.";
  c.layoutMode = "HORIZONTAL";
  c.counterAxisAlignItems = "CENTER";
  c.primaryAxisSizingMode = "FIXED";
  c.counterAxisSizingMode = "FIXED";
  c.resize(DEVICE_WIDTH - 2 * metric("margin/side"), metric("voicebar/height"));
  await bind(c, "height", "Metrics:voicebar/height");
  await bind(c, "itemSpacing", "Metrics:term/gap");
  await bind(c, "paddingLeft", "Metrics:term/inset");
  await bind(c, "paddingRight", "Metrics:term/inset");
  const cancel = await glyphButton("Cancel", "xmark", "×", "Keyboard:kb/legend", "Metrics:opacity/term-cancel");
  cancel.name = "Cancel";
  const cancelInstance = cancel.createInstance();
  cancel.remove();
  c.appendChild(cancelInstance);
  const field = figma.createFrame();
  field.name = "Field";
  field.layoutMode = "HORIZONTAL";
  field.counterAxisAlignItems = "CENTER";
  field.primaryAxisSizingMode = "FIXED";
  field.counterAxisSizingMode = "FIXED";
  field.resize(100, metric("term/height"));
  await bind(field, "height", "Metrics:term/height");
  await bind(field, "paddingLeft", "Metrics:term/pad");
  await bind(field, "paddingRight", "Metrics:term/pad");
  field.fills = [await paint("Keyboard:kb/key-modifier")];
  field.cornerRadius = metric("term/height") / 2; // a capsule: half the height
  const draft = await textNode("Rizz", { styleId: await textStyleId("Term/Text"), fillRef: "Keyboard:kb/legend" });
  draft.name = "Draft";
  field.appendChild(draft);
  const caret = figma.createRectangle();
  caret.name = "Caret";
  caret.resize(metric("caret/width"), metric("caret/height"));
  await bind(caret, "width", "Metrics:caret/width");
  await bind(caret, "height", "Metrics:caret/height");
  await bindRadius(caret, "Metrics:caret/radius");
  caret.fills = [await paint("Keyboard:kb/signal")];
  field.appendChild(caret);
  c.appendChild(field);
  field.layoutSizingHorizontal = "FILL";
  const save = await glyphButton("Save", "checkmark", "✓", "Keyboard:kb/signal", null);
  const saveInstance = save.createInstance();
  save.remove();
  c.appendChild(saveInstance);
  const draftProp = c.addComponentProperty("Draft", "TEXT", "Rizz");
  draft.componentPropertyReferences = { characters: draftProp };
  replaceNamed(page, "TermField", c);
  page.appendChild(c);
  c.x = x;
  c.y = y;
  return c;
}

async function buildOrbRing(page, x, y) {
  const variants = [];
  for (const [size, ref] of Object.entries(SIZES)) {
    for (const kind of ["Still", "Working", "Ok", "Error"]) {
      const c = figma.createComponent();
      c.name = `Kind=${kind}, Size=${size}`;
      const d = metric(ref);
      c.resize(d, d);
      c.fills = [];
      const ring = figma.createEllipse();
      ring.name = "Ring";
      ring.resize(d, d);
      ring.fills = [];
      ring.strokeAlign = "INSIDE";
      if (kind === "Ok" || kind === "Error") {
        ring.strokes = [await paint(kind === "Ok" ? "Keyboard:kb/notice-ok" : "Keyboard:kb/notice-error")];
      } else {
        ring.strokes = [gradientPaint("orb-ring")];
      }
      await bind(ring, "strokeWeight", kind === "Still" ? "Metrics:ring/still" : "Metrics:ring/active");
      c.appendChild(ring);
      await bind(c, "width", `Metrics:${ref}`);
      await bind(c, "height", `Metrics:${ref}`);
      variants.push(c);
    }
  }
  replaceNamed(page, "Orb/Ring", variants[0]);
  const set = finishSet(page, "Orb/Ring", variants, x, y);
  set.description = "The hairline ring round the orb: green into white, 1 pt at rest and 2 pt while working (it sweeps one turn per 1.6 s); solid green for pasted and copied, orange for an error.";
  return set;
}

/** An orb still the app rendered, if one has been placed in the file. */
function orbStill(page, size, mood) {
  const node = page.findOne((n) => n.name === `orb-still/${size}-${mood}`.toLowerCase());
  if (!node || !("fills" in node)) return null;
  const fill = node.fills.find((f) => f.type === "IMAGE");
  return fill ? fill.imageHash : null;
}

async function buildOrbDisc(page, x, y) {
  const variants = [];
  let images = 0;
  for (const [size, ref] of Object.entries(SIZES)) {
    for (const mood of ["Off", "Idle", "Listening", "Working", "Landed"]) {
      const c = figma.createComponent();
      c.name = `Size=${size}, Mood=${mood}`;
      const d = metric(ref);
      c.resize(d, d);
      c.fills = [];
      const disc = figma.createEllipse();
      disc.name = "Disc";
      disc.resize(d, d);
      const hash = orbStill(page, size, mood === "Off" ? "Idle" : mood);
      if (hash) {
        disc.fills = [{ type: "IMAGE", imageHash: hash, scaleMode: "FILL" }];
        images += 1;
      } else {
        disc.fills = [gradientPaint("orb")];
      }
      if (mood === "Off") {
        await bind(disc, "opacity", "Metrics:opacity/dim");
      }
      c.appendChild(disc);
      await bind(c, "width", `Metrics:${ref}`);
      await bind(c, "height", `Metrics:${ref}`);
      variants.push(c);
    }
  }
  replaceNamed(page, "Orb/Disc", variants[0]);
  const set = finishSet(page, "Orb/Disc", variants, x, y);
  set.description =
    "The orb's fill. A still the app renders (-BlurtOrb <size> <mood>, placed here as orb-still/<size>-<mood>); the brand gradient stands in until one is. Off is Idle dimmed.";
  return { set, images };
}

async function buildWaveformMeter(page, x, y) {
  const variants = [];
  for (const [size, [wRef, hRef]] of Object.entries(WAVES)) {
    const c = figma.createComponent();
    c.name = `Size=${size}`;
    const w = metric(wRef);
    const h = metric(hRef);
    c.resize(w, h);
    c.fills = [];
    c.layoutMode = "HORIZONTAL";
    c.primaryAxisAlignItems = "CENTER";
    c.counterAxisAlignItems = "CENTER";
    c.primaryAxisSizingMode = "FIXED";
    c.counterAxisSizingMode = "FIXED";
    await bind(c, "itemSpacing", "Metrics:wave/gap");
    await bind(c, "width", `Metrics:${wRef}`);
    await bind(c, "height", `Metrics:${hRef}`);
    const bar = metric("wave/bar");
    const gap = metric("wave/gap");
    const count = Math.floor((w + gap) / (bar + gap));
    const level = 0.62;
    for (let i = 0; i < count; i += 1) {
      const t = i / Math.max(count - 1, 1);
      // A schematic of the engine's envelope: a soft hump, minimum 12 %, at the gallery's level.
      const envelope = 0.12 + 0.88 * level * Math.pow(Math.sin(Math.PI * t), 0.45);
      const capsule = figma.createRectangle();
      capsule.name = "Bar";
      capsule.resize(bar, Math.max(bar, h * envelope));
      capsule.cornerRadius = bar / 2;
      await bind(capsule, "width", "Metrics:wave/bar");
      capsule.fills = [await paint("Keyboard:kb/signal")];
      c.appendChild(capsule);
    }
    variants.push(c);
  }
  replaceNamed(page, "WaveformMeter", variants[0]);
  const set = finishSet(page, "WaveformMeter", variants, x, y);
  set.description =
    "The thin wave: 2 pt bars 2 pt apart, flat on the surface, no container. Heights are the engine's (MeterBarGeometry); this is the schematic at level 0.62 — fidelity frames use app captures.";
  return set;
}

const MIC_STATES = ["Off", "Idle", "Working", "Recording", "Pasted", "Copied", "Error"];

async function buildMicKey(page, x, y) {
  const disc = await findComponentSet(page, "Orb/Disc");
  const ring = await findComponentSet(page, "Orb/Ring");
  const meter = await findComponentSet(page, "WaveformMeter");
  if (!disc || !ring || !meter) throw new Error("build Orb/Disc, Orb/Ring and WaveformMeter first");
  const pick = (set, props) =>
    set.children.find((c) => Object.entries(props).every(([k, v]) => c.name.includes(`${k}=${v}`)));
  const variants = [];
  for (const [size, ref] of Object.entries(SIZES)) {
    for (const state of MIC_STATES) {
      const c = figma.createComponent();
      c.name = `Size=${size}, State=${state}`;
      const d = metric(ref);
      const [wRef] = WAVES[size];
      c.resize(Math.max(metric(wRef), d), d);
      c.fills = [];
      c.layoutMode = "HORIZONTAL";
      c.primaryAxisAlignItems = "CENTER";
      c.counterAxisAlignItems = "CENTER";
      c.primaryAxisSizingMode = "FIXED";
      c.counterAxisSizingMode = "FIXED";
      await bind(c, "height", `Metrics:${ref}`);
      if (state === "Recording") {
        c.appendChild(pick(meter, { Size: size }).createInstance());
      } else {
        const stack = figma.createFrame();
        stack.name = "Orb";
        stack.resize(d, d);
        stack.fills = [];
        stack.clipsContent = false;
        const mood = { Off: "Off", Idle: "Idle", Working: "Working", Pasted: "Landed", Copied: "Idle", Error: "Idle" }[state];
        const kind = { Off: "Still", Idle: "Still", Working: "Working", Pasted: "Ok", Copied: "Ok", Error: "Error" }[state];
        const discInstance = pick(disc, { Size: size, Mood: mood }).createInstance();
        discInstance.name = "Disc";
        stack.appendChild(discInstance);
        const ringInstance = pick(ring, { Size: size, Kind: kind }).createInstance();
        ringInstance.name = "Ring";
        stack.appendChild(ringInstance);
        if (state === "Copied" || state === "Error") {
          const glyph = await textNode(
            state === "Copied" ? symbolChar("doc.on.clipboard", "⎘") : symbolChar("exclamationmark", "!"),
            { size: d * token("Typography", "ratio/orb-glyph").value, weight: FONT.semibold }
          );
          glyph.name = "Glyph";
          glyph.fills = [{ type: "SOLID", color: { r: 1, g: 1, b: 1 } }];
          stack.appendChild(glyph);
          glyph.x = (d - glyph.width) / 2;
          glyph.y = (d - glyph.height) / 2;
        }
        if (state === "Off") await bind(stack, "opacity", "Metrics:opacity/dim");
        c.appendChild(stack);
      }
      variants.push(c);
    }
  }
  replaceNamed(page, "MicKey", variants[0]);
  const set = finishSet(page, "MicKey", variants, x, y);
  set.description =
    "The mic key is the orb, and it says everything without a word: dimmed when Blurt isn't ready; ring sweeping while connecting and transcribing; dissipated into the wave while recording; a green ring when the words landed (with the drop), a clipboard on green when they went to the clipboard, orange and ! for an error.";
  return set;
}

async function buildVoiceBar(page, x, y) {
  const mic = await findComponentSet(page, "MicKey");
  const addTerm = await findComponentSet(page, "AddTermKey");
  const termField = await findComponent(page, "TermField");
  if (!mic || !addTerm || !termField) throw new Error("build MicKey, AddTermKey and TermField first");
  const pick = (set, props) =>
    set.children.find((c) => Object.entries(props).every(([k, v]) => c.name.includes(`${k}=${v}`)));
  const variants = [];
  for (const mode of ["Orb", "Wave", "Term", "NoFullAccess"]) {
    const c = figma.createComponent();
    c.name = `Mode=${mode}`;
    c.layoutMode = "HORIZONTAL";
    c.primaryAxisAlignItems = mode === "NoFullAccess" ? "MIN" : "CENTER";
    c.counterAxisAlignItems = "CENTER";
    c.primaryAxisSizingMode = "FIXED";
    c.counterAxisSizingMode = "FIXED";
    c.resize(DEVICE_WIDTH - 2 * metric("margin/side"), metric("voicebar/height"));
    await bind(c, "height", "Metrics:voicebar/height");
    c.fills = [];
    c.clipsContent = false;
    if (mode === "Term") {
      const f = termField.createInstance();
      c.appendChild(f);
      f.layoutSizingHorizontal = "FILL";
    } else if (mode === "NoFullAccess") {
      await bind(c, "itemSpacing", "Metrics:voicebar/note-gap");
      c.appendChild(pick(mic, { Size: "Bar", State: "Off" }).createInstance());
      const note = await textNode("Allow Full Access in Settings → Keyboards", {
        size: 13,
        fillRef: "Keyboard:kb/full-access-note",
      });
      note.name = "Note";
      c.appendChild(note);
    } else {
      c.appendChild(pick(mic, { Size: "Bar", State: mode === "Wave" ? "Recording" : "Idle" }).createInstance());
      const plus = pick(addTerm, { Saved: "False" }).createInstance();
      c.appendChild(plus);
      plus.layoutPositioning = "ABSOLUTE";
      plus.constraints = { horizontal: "MAX", vertical: "CENTER" };
      plus.x = c.width - plus.width;
      plus.y = (c.height - plus.height) / 2;
    }
    variants.push(c);
  }
  replaceNamed(page, "VoiceBar", variants[0]);
  const set = finishSet(page, "VoiceBar", variants, x, y);
  set.description =
    "The keyboard's voice row, and the only place voice lives: the orb (the mic key) dissipating into the wave while recording; the + for a key term; the field the keys type into; the one line of words, without Full Access.";
  return set;
}

async function buildComponents() {
  const page = await getPage(PAGES.components);
  VARS = await variableMap();
  await loadFonts();
  const built = {};
  let y = 0;
  const step = 360;
  built.key = (await buildKeySet(page, 0, y)).id;
  built.letterKey = (await buildLetterKeySet(page, 0, (y += step))).id;
  built.addTermKey = (await buildAddTermKey(page, 0, (y += step))).id;
  built.cancelKey = (await buildCancelKey(page, 400, y)).id;
  built.termField = (await buildTermField(page, 0, (y += step))).id;
  built.orbRing = (await buildOrbRing(page, 0, (y += step))).id;
  const disc = await buildOrbDisc(page, 0, (y += step));
  built.orbDisc = disc.set.id;
  built.orbStillsUsed = disc.images;
  built.waveformMeter = (await buildWaveformMeter(page, 0, (y += step))).id;
  built.micKey = (await buildMicKey(page, 0, (y += step))).id;
  built.voiceBar = (await buildVoiceBar(page, 0, (y += step))).id;
  return { page: page.id, built };
}

// ---------------------------------------------------------------------------
// Layouts (03 Layouts): the three keyboards as frames of instances, one per
// state, named exactly as the gallery captions them (<layout>/<state>/<theme>)

const STATE_TO_MIC = {
  off: "Off",
  start: "Off",
  idle: "Idle",
  connecting: "Working",
  recording: "Recording",
  processing: "Working",
  pasted: "Pasted",
  copied: "Copied",
  error: "Error",
  landed: "Pasted",
};

async function layoutRoot(name, height) {
  const f = figma.createFrame();
  f.name = name;
  f.layoutMode = "VERTICAL";
  f.primaryAxisSizingMode = "FIXED";
  f.counterAxisSizingMode = "FIXED";
  f.resize(DEVICE_WIDTH, height);
  f.fills = [await paint("Keyboard:kb/surface")];
  f.clipsContent = true;
  await bind(f, "paddingLeft", "Metrics:margin/side");
  await bind(f, "paddingRight", "Metrics:margin/side");
  await bind(f, "paddingTop", "Metrics:margin/vertical");
  await bind(f, "paddingBottom", "Metrics:margin/vertical");
  return f;
}

async function keyInstance(sets, tone, label, widthRef) {
  const variant = sets.key.children.find((c) => c.name.includes(`Tone=${tone}`) && c.name.includes("State=Up"));
  const i = variant.createInstance();
  const labelKey = Object.keys(i.componentProperties).find((k) => k.startsWith("Label"));
  i.setProperties({ [labelKey]: label });
  i.name = label === "space" ? "space" : `key ${label}`;
  if (widthRef) {
    i.layoutSizingHorizontal = "FIXED";
    i.resize(metric(widthRef), i.height);
    await bind(i, "width", `Metrics:${widthRef}`);
  }
  return i;
}

async function bottomRow(sets, parent, { withSymbols }) {
  const row = autoLayout("HORIZONTAL", { name: "bottom row" });
  await bind(row, "itemSpacing", "Metrics:key/gap");
  row.counterAxisAlignItems = "CENTER";
  parent.appendChild(row);
  row.layoutSizingHorizontal = "FILL";
  if (withSymbols) row.appendChild(await keyInstance(sets, "Modifier", "123", "key/side-width-402"));
  row.appendChild(await keyInstance(sets, "Modifier", symbolChar("globe", "🌐"), withSymbols ? "key/side-width-402" : null));
  const space = await keyInstance(sets, "Key", "space", null);
  row.appendChild(space);
  space.layoutSizingHorizontal = "FILL";
  if (!withSymbols) row.appendChild(await keyInstance(sets, "Modifier", symbolChar("delete.left", "⌫"), null));
  row.appendChild(
    await keyInstance(sets, "Modifier", symbolChar("return", "↩"), withSymbols ? "key/return-width-402" : null)
  );
  return row;
}

async function buildPanelFrame(sets, state, theme) {
  const f = await layoutRoot(`panel/${state}/${theme}`, metric("layout/panel"));
  await bind(f, "itemSpacing", "Metrics:panel/spacing");
  const voice = autoLayout("VERTICAL", { name: "voice" });
  voice.primaryAxisAlignItems = "CENTER";
  voice.counterAxisAlignItems = "CENTER";
  f.appendChild(voice);
  voice.layoutSizingHorizontal = "FILL";
  voice.layoutSizingVertical = "FILL";
  const mic = sets.micKey.children
    .find((c) => c.name.includes("Size=Panel") && c.name.includes(`State=${STATE_TO_MIC[state] || "Idle"}`))
    .createInstance();
  mic.name = "MicKey";
  voice.appendChild(mic);
  await bottomRow(sets, f, { withSymbols: false });
  const plus = sets.addTermKey.children.find((c) => c.name.includes("Saved=False")).createInstance();
  plus.name = "AddTermKey";
  f.appendChild(plus);
  plus.layoutPositioning = "ABSOLUTE";
  plus.x = metric("addterm/inset");
  plus.y = metric("addterm/inset");
  if (["connecting", "recording", "processing"].includes(state)) {
    const cancel = sets.cancelKey.createInstance();
    cancel.name = "CancelKey";
    f.appendChild(cancel);
    cancel.layoutPositioning = "ABSOLUTE";
    cancel.constraints = { horizontal: "MAX", vertical: "MIN" };
    cancel.x = DEVICE_WIDTH - metric("margin/side") - cancel.width;
    cancel.y = metric("margin/vertical");
  }
  return f;
}

async function voiceBarInstance(sets, state, hasFullAccess) {
  const mode = !hasFullAccess ? "NoFullAccess" : state === "term" ? "Term" : state === "recording" ? "Wave" : "Orb";
  const i = sets.voiceBar.children.find((c) => c.name.includes(`Mode=${mode}`)).createInstance();
  i.name = "VoiceBar";
  if (mode === "Orb") {
    const mic = i.findOne((n) => n.type === "INSTANCE" && n.name.startsWith("Size=Bar"));
    if (mic) {
      const target = sets.micKey.children.find(
        (c) => c.name.includes("Size=Bar") && c.name.includes(`State=${STATE_TO_MIC[state] || "Idle"}`)
      );
      if (target) mic.swapComponent(target);
    }
  }
  return i;
}

async function buildSlimBarFrame(sets, state, theme) {
  const f = await layoutRoot(`slimBar/${state}/${theme}`, metric("layout/slim"));
  const row = autoLayout("HORIZONTAL", { name: "row" });
  await bind(row, "itemSpacing", "Metrics:slim/spacing");
  row.counterAxisAlignItems = "CENTER";
  f.appendChild(row);
  row.layoutSizingHorizontal = "FILL";
  row.appendChild(await keyInstance(sets, "Modifier", symbolChar("globe", "🌐"), null));
  const bar = await voiceBarInstance(sets, state, state !== "off");
  row.appendChild(bar);
  bar.layoutSizingHorizontal = "FILL";
  row.appendChild(await keyInstance(sets, "Modifier", symbolChar("delete.left", "⌫"), null));
  row.appendChild(await keyInstance(sets, "Modifier", symbolChar("return", "↩"), null));
  return f;
}

async function buildFullFrame(sets, state, theme) {
  const f = await layoutRoot(`full/${state}/${theme}`, metric("layout/full"));
  await bind(f, "itemSpacing", "Metrics:row/gap");
  const bar = await voiceBarInstance(sets, state, state !== "off");
  f.appendChild(bar);
  bar.layoutSizingHorizontal = "FILL";
  const rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"];
  const letter = (ch) => {
    const v = sets.letterKey.children.find((c) => c.name.includes("State=Up")).createInstance();
    const labelKey = Object.keys(v.componentProperties).find((k) => k.startsWith("Label"));
    v.setProperties({ [labelKey]: ch });
    v.name = `key ${ch}`;
    return v;
  };
  for (const [index, letters] of rows.entries()) {
    const row = autoLayout("HORIZONTAL", { name: `row ${index + 1}` });
    row.primaryAxisAlignItems = "CENTER";
    row.counterAxisAlignItems = "CENTER";
    f.appendChild(row);
    row.layoutSizingHorizontal = "FILL";
    if (index === 2) {
      row.itemSpacing = metric("key/gap") * metric("key/side-gap-factor");
      row.appendChild(await keyInstance(sets, "Modifier", symbolChar("shift", "⇧"), "key/side-width-402"));
      const inner = autoLayout("HORIZONTAL", { name: "letters" });
      await bind(inner, "itemSpacing", "Metrics:key/gap");
      row.appendChild(inner);
      for (const ch of letters) inner.appendChild(letter(ch));
      row.appendChild(await keyInstance(sets, "Modifier", symbolChar("delete.left", "⌫"), "key/side-width-402"));
    } else {
      await bind(row, "itemSpacing", "Metrics:key/gap");
      for (const ch of letters) row.appendChild(letter(ch));
    }
  }
  await bottomRow(sets, f, { withSymbols: true });
  return f;
}

async function buildLayouts() {
  const components = await getPage(PAGES.components);
  const sets = {
    key: await findComponentSet(components, "Key"),
    letterKey: await findComponentSet(components, "LetterKey"),
    addTermKey: await findComponentSet(components, "AddTermKey"),
    cancelKey: await findComponent(components, "CancelKey"),
    micKey: await findComponentSet(components, "MicKey"),
    voiceBar: await findComponentSet(components, "VoiceBar"),
  };
  for (const [name, set] of Object.entries(sets)) if (!set) throw new Error(`component ${name} missing — run buildComponents first`);
  const page = await getPage(PAGES.layouts);
  VARS = await variableMap();
  await loadFonts();
  const builders = { Panel: buildPanelFrame, SlimBar: buildSlimBarFrame, Full: buildFullFrame };
  const built = {};
  let sectionX = 0;
  for (const [name, build] of Object.entries(builders)) {
    const section = getSection(page, name, sectionX, 0);
    for (const child of [...section.children]) child.remove();
    const states = name === "Panel" ? STATES.filter((s) => s !== "term") : STATES;
    let y = 40;
    const ids = [];
    for (const state of states) {
      const caption = await textNode(`${name.charAt(0).toLowerCase() + name.slice(1)} · ${state} · ${DESIGN_THEME}`, {
        size: 11,
        weight: FONT.medium,
        fillRef: "Brand:ink",
      });
      section.appendChild(caption);
      caption.x = 40;
      caption.y = y;
      y += 20;
      const frame = await build(sets, state, DESIGN_THEME);
      section.appendChild(frame);
      frame.x = 40;
      frame.y = y;
      y += frame.height + 40;
      ids.push(frame.id);
    }
    section.resizeWithoutConstraints(DEVICE_WIDTH + 80, y);
    built[name] = ids;
    sectionX += DEVICE_WIDTH + 160;
  }
  return { page: page.id, built };
}

// ---------------------------------------------------------------------------
// Themes: kb/* re-aliased to each theme's set in turn, the idle frames
// exported at 3× and placed as images, then ink restored. This is
// KeyboardPalette.resolve(_:dark:) in Figma — a Starter file has one mode.

async function setDesignTheme(theme) {
  VARS = await variableMap();
  const keyboard = (await figma.variables.getLocalVariableCollectionsAsync()).find((c) => c.name === "Keyboard");
  const modeId = keyboard.modes[0].modeId;
  for (const role of ROLES) {
    const kb = VARS.get(`Keyboard:kb/${role}`);
    const target = VARS.get(`Themes:${theme}/${role}`);
    if (!kb || !target) throw new Error(`no variable for kb/${role} → ${theme}`);
    kb.setValueForMode(modeId, figma.variables.createVariableAlias(target));
  }
}

async function themeSheet() {
  const page = await getPage(PAGES.layouts);
  const sheet = getSection(page, "Theme sheet", 3 * (DEVICE_WIDTH + 160), 0);
  for (const child of [...sheet.children]) child.remove();
  const idle = page.findAll((n) => n.type === "FRAME" && /^(panel|slimBar|full)\/idle\//.test(n.name));
  if (idle.length === 0) throw new Error("no idle layout frames — run buildLayouts first");
  const placed = [];
  let y = 40;
  try {
    for (const theme of THEMES) {
      await setDesignTheme(theme);
      let x = 40;
      let rowHeight = 0;
      for (const frame of idle) {
        const bytes = await frame.exportAsync({ format: "PNG", constraint: { type: "SCALE", value: 3 } });
        const image = figma.createImage(bytes);
        const rect = figma.createRectangle();
        rect.name = frame.name.replace(`/${DESIGN_THEME}`, `/${theme}`);
        rect.resize(frame.width, frame.height);
        rect.fills = [{ type: "IMAGE", imageHash: image.hash, scaleMode: "FILL" }];
        sheet.appendChild(rect);
        rect.x = x;
        rect.y = y;
        x += frame.width + 40;
        rowHeight = Math.max(rowHeight, frame.height);
        placed.push(rect.id);
      }
      y += rowHeight + 60;
    }
  } finally {
    await setDesignTheme(DESIGN_THEME);
  }
  sheet.resizeWithoutConstraints(idle.reduce((w, f) => w + f.width + 40, 40), y);
  return { sheet: sheet.id, placed: placed.length, themes: THEMES.length };
}

/** Bounds of whatever was pasted from Apple's kit under "Apple reference". */
async function measureApple() {
  const page = await getPage(PAGES.layouts);
  const section = page.children.find((n) => n.type === "SECTION" && n.name === "Apple reference");
  if (!section) throw new Error('no "Apple reference" section — paste the iOS 27 Keyboard instances into one');
  const out = {};
  for (const root of section.children) {
    const origin = root.absoluteBoundingBox;
    out[root.name] = root
      .findAll((n) => n.absoluteBoundingBox && n.name)
      .map((n) => {
        const b = n.absoluteBoundingBox;
        const radius = "cornerRadius" in n && typeof n.cornerRadius === "number" ? n.cornerRadius : null;
        return { name: n.name, x: +(b.x - origin.x).toFixed(2), y: +(b.y - origin.y).toFixed(2), w: +b.width.toFixed(2), h: +b.height.toFixed(2), radius };
      });
  }
  return out;
}
