import BlurtiOSCore

extension KeyboardModel {
  /// The chosen theme's palette in the host's appearance — or, for a
  /// preview, the face it is told (`faceOverride`).
  var palette: KeyboardPalette {
    .resolve(faceOverride?.themeID ?? themeID, dark: faceOverride?.dark ?? isDark)
  }
}

extension ThemeFace {
  /// The face a palette is: what a preview hands the model to draw it.
  init(_ palette: KeyboardPalette) {
    self.init(themeID: palette.id, dark: palette.face == .dark)
  }
}
