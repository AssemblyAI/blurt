/* global figma, getPage, getSection, variableMap, ensureTokens, loadFonts, FONT, metric, autoLayout, textNode, paint, bind, symbolChar, DEVICE_WIDTH, DESIGN_THEME, STATES, PAGES, findComponentSet, findComponent, VARS */
// ---------------------------------------------------------------------------
// Layouts (03 Layouts): the three keyboards as frames of instances, one per
// state, named exactly as the gallery captions them (<layout>/<state>/<theme>)

/** The instance's label, written on its text node: setProperties refuses a
 * text property whose font Figma marks missing, which it does for the local
 * SF Pro under the MCP runtime even after loadFontAsync; a direct write goes
 * through, and renders the same. */
function setLabel(instance, label) {
  const t = instance.findOne((n) => n.type === "TEXT" && n.name === "Label");
  if (t) t.characters = label;
}

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
  setLabel(i, label);
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
    setLabel(v, ch);
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
  await ensureTokens();
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
