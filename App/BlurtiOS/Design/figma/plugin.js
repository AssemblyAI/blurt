// The development-plugin entry: scripts/design-sync.sh concatenates
// tokens.js + lib.js + this file into .build/figma-plugin/code.js. Each menu
// command in manifest.json runs one builder; the result's first line is shown
// as the plugin closes, the whole thing is in the console.
/* global figma, buildFoundations, buildComponents, buildLayouts, themeSheet, exportTokens, exportBounds, measureApple */

const COMMANDS = {
  foundations: buildFoundations,
  components: buildComponents,
  layouts: buildLayouts,
  "theme-sheet": themeSheet,
  "export-tokens": exportTokens,
  "export-bounds": exportBounds,
  "measure-apple": measureApple,
};

(async () => {
  const run = COMMANDS[figma.command];
  if (!run) {
    figma.closePlugin(`unknown command ${figma.command}`);
    return;
  }
  try {
    const result = await run();
    console.log(JSON.stringify(result, null, 2));
    figma.closePlugin(`${figma.command}: done (result in the console)`);
  } catch (error) {
    console.error(error);
    figma.closePlugin(`${figma.command}: ${error.message}`);
  }
})();
