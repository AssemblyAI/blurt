import BlurtiOSCore

extension KeyboardModel {
  /// The palette for the face the model draws (`KeyboardModel.face`) on a
  /// profile's generation: the system theme exists on classic alone.
  func palette(for profile: KeyboardProfile) -> KeyboardPalette {
    .resolve(face.themeID, dark: face.dark, generation: profile.generation)
  }
}

extension ThemeFace {
  /// The face a palette is: what a preview hands the model to draw it.
  init(_ palette: KeyboardPalette) {
    self.init(themeID: palette.id, dark: palette.face == .dark)
  }
}
