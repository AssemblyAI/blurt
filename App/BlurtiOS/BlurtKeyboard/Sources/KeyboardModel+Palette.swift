import BlurtiOSCore

extension KeyboardModel {
  /// The palette for the face the model draws (`KeyboardModel.face`).
  var palette: KeyboardPalette { .resolve(face.themeID, dark: face.dark) }
}

extension ThemeFace {
  /// The face a palette is: what a preview hands the model to draw it.
  init(_ palette: KeyboardPalette) {
    self.init(themeID: palette.id, dark: palette.face == .dark)
  }
}
