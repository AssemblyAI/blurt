/* global figma, getPage, getSection, variableMap, ensureTokens, DEVICE_WIDTH, DESIGN_THEME, THEMES, ROLES, PAGES, VARS */
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
  await ensureTokens();
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
