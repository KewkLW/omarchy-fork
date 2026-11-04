pragma Singleton
import QtQuick
import "BorderGeometry.js" as Geometry

// Central border-spec factory for shell surfaces and controls. A spec carries
// color, optional gradient, and top/right/bottom/left widths so renderers can
// choose the cheap Rectangle path or the Shape-ring path without duplicating
// theme parsing logic.
QtObject {
  id: root

  function none() {
    return flat("transparent", 0)
  }

  function flat(color, width) {
    return {
      color: color || "transparent",
      widths: Geometry.parseWidthSpec(width, 0),
      gradient: { colors: [], angle: 0, enabled: false },
    }
  }

  function value(section, key) {
    var v = Color.shellValues[section + "." + key]
    return (v === undefined || v === null) ? "" : v
  }

  function valueOr(section, keys) {
    for (var i = 0; i < keys.length; i++) {
      var v = value(section, keys[i])
      if (String(v).length > 0) return v
    }
    return ""
  }

  function resolveValueRef(raw) {
    var s = String(raw || "").replace(/^\s+|\s+$/g, "")
    var seen = {}
    while (s.match(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/) && !seen[s]) {
      seen[s] = true
      var next = Color.shellValues[s]
      if (next === undefined || next === null || String(next).length === 0) break
      s = String(next).replace(/^\s+|\s+$/g, "")
    }
    return s
  }

  function alpha(section, key, fallback) {
    var raw = value(section, key)
    if (String(raw).length === 0) return fallback
    var n = Number(raw)
    return isFinite(n) ? Geometry.clampAlpha(n) : fallback
  }

  function cssColor(color, opacity) {
    var a = opacity === undefined || opacity === null ? 1 : Geometry.clampAlpha(opacity)
    if (color && typeof color === "object" && color.r !== undefined) {
      if (typeof Qt !== "undefined" && Qt.rgba) {
        return Qt.rgba(color.r, color.g, color.b, (color.a === undefined ? 1 : color.a) * a)
      }
      return "#"
        + Geometry.padHex(color.r * 255)
        + Geometry.padHex(color.g * 255)
        + Geometry.padHex(color.b * 255)
        + Geometry.padHex((color.a === undefined ? 1 : color.a) * a * 255)
    }

    var s = String(color || "").replace(/^\s+|\s+$/g, "")
    var role = s.toLowerCase()
    if (role === "foreground" || role === "text") return cssColor(Color.foreground, a)
    if (role === "accent") return cssColor(Color.accent, a)
    if (role === "urgent") return cssColor(Color.urgent, a)
    if (role === "background") return cssColor(Color.background, a)
    if (role === "transparent") return "transparent"
    return Geometry.canonicalColor(s, a)
  }

  function resolvedGradient(raw, fallbackColor, opacity) {
    var s = String(raw || "").replace(/^\s+|\s+$/g, "")
    if (s.length === 0) return { colors: [], angle: 0, enabled: false }

    var parts = s.split(/\s+/)
    var colors = []
    var angle = 0
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].match(/^-?\d+(?:\.\d+)?deg$/)) angle = Number(parts[i].replace(/deg$/, ""))
      else colors.push(cssColor(parts[i], opacity))
    }
    if (colors.length === 0) colors.push(cssColor(fallbackColor, opacity))
    return { colors: colors, angle: angle, enabled: colors.length > 1 }
  }

  function sameColor(a, b) {
    if (typeof Qt === "undefined" || !Qt.color) return String(a) === String(b)
    var ca = typeof a === "string" ? Qt.color(a) : a
    var cb = typeof b === "string" ? Qt.color(b) : b
    if (!ca || !cb || ca.r === undefined || cb.r === undefined) return String(a) === String(b)
    return Math.round(ca.r * 255) === Math.round(cb.r * 255)
      && Math.round(ca.g * 255) === Math.round(cb.g * 255)
      && Math.round(ca.b * 255) === Math.round(cb.b * 255)
      && Math.round((ca.a === undefined ? 1 : ca.a) * 255) === Math.round((cb.a === undefined ? 1 : cb.a) * 255)
  }

  function localOrSurfaceSpec(section, token, localColor, defaultColor, fallbackWidth, alphaKey) {
    if (!sameColor(localColor, defaultColor)) return flat(localColor, fallbackWidth)
    return surfaceSpec(section, token, localColor, fallbackWidth, alphaKey)
  }

  function surfaceWidths(section, token, fallbackWidth) {
    var base = valueOr(section, token === "border" ? ["border-width"] : [token + "-width", "border-width"])
    var widths = Geometry.parseWidthSpec(base, fallbackWidth)
    return Geometry.withSideOverrides(
      widths,
      valueOr(section, token === "border" ? ["border-width-top"] : [token + "-width-top", "border-width-top"]),
      valueOr(section, token === "border" ? ["border-width-right"] : [token + "-width-right", "border-width-right"]),
      valueOr(section, token === "border" ? ["border-width-bottom"] : [token + "-width-bottom", "border-width-bottom"]),
      valueOr(section, token === "border" ? ["border-width-left"] : [token + "-width-left", "border-width-left"])
    )
  }

  function borderValue(raw, fallbackColor, opacity, legacyGradientRaw) {
    var fallback = cssColor(fallbackColor, opacity)
    var primaryRaw = String(raw || "").replace(/^\s+|\s+$/g, "")
    var primary = resolvedGradient(primaryRaw.length > 0 ? primaryRaw : fallbackColor, fallbackColor, opacity)
    var color = primary.colors.length > 0 ? primary.colors[0] : fallback
    var gradient = primary.enabled ? primary : { colors: [], angle: 0, enabled: false }

    // Backward compatibility for existing configs written during the separate
    // border-gradient experiment. New configs put solid colors and gradients in
    // the same border token.
    if (!gradient.enabled && String(legacyGradientRaw || "").replace(/^\s+|\s+$/g, "").length > 0) {
      var legacy = resolvedGradient(legacyGradientRaw, color, opacity)
      if (legacy.enabled) gradient = legacy
    }

    return { color: color, gradient: gradient }
  }

  // Image frame for a surface section: a 9-slice PNG drawn instead of the
  // colour border. Paths are relative to the current theme directory.
  //   frame        = "frames/dialog.png"  9-slice source image
  //   frame-slice  = 32                   source px cut from each edge
  //   frame-width  = 56                   rendered edge thickness
  //   frame-inset  = 30                   content inset (default frame-width)
  //   frame-fill   = "frames/fill.png"    optional tiled fill under content
  //   frame-fill-inset = 19               fill inset from the outer edge
  //   frame-fill-alpha = 0.95
  //   frame-mode   = "stretch"            draw the whole image scaled to the
  //                                       surface instead of 9-slicing it
  //   frame-outset = 7                    draw the frame this many px past the
  //                                       surface edge, for art with a
  //                                       transparent margin or outer glow
  // frame-inset also takes a CSS-style list ("T R B L") for art whose
  // content area is not centred.
  //
  // Other image tokens reuse the same keys under their own prefix, e.g.
  // [osd] progress-frame, progress-frame-slice, progress-frame-mode.
  function themeFile(rel) {
    var s = String(rel || "").replace(/^\s+|\s+$/g, "")
    if (s.length === 0) return ""
    if (s.charAt(0) === "/") return "file://" + s
    return "file://" + Color.currentThemePath + "/" + s
  }

  // A theme image token ([section] key = "path"), as a file URL or "".
  function image(section, key) {
    return themeFile(value(section, key))
  }

  function number(section, key, fallback) {
    var n = Number(value(section, key))
    return String(value(section, key)).length > 0 && isFinite(n) && n >= 0 ? n : fallback
  }

  function frameSpec(section, prefix) {
    var p = prefix || "frame"
    var source = themeFile(value(section, p))
    if (source.length === 0) return null
    var slice = number(section, p + "-slice", 16)
    var width = number(section, p + "-width", slice)
    var inset = value(section, p + "-inset")
    return {
      source: source,
      stretch: String(value(section, p + "-mode")) === "stretch",
      slice: slice,
      width: width,
      inset: String(inset).length > 0 ? inset : width,
      outset: number(section, p + "-outset", 0),
      fill: themeFile(value(section, p + "-fill")),
      fillInset: number(section, p + "-fill-inset", 0),
      fillAlpha: alpha(section, p + "-fill-alpha", 1.0),
    }
  }

  // A border spec that is only an image frame, for controls and parts that
  // have no colour border of their own (null when the theme sets no image).
  function frameOnlySpec(section, prefix) {
    var frame = frameSpec(section, prefix)
    if (!frame) return null
    return {
      color: "transparent",
      widths: Geometry.parseWidthSpec(frame.inset, 0),
      gradient: { colors: [], angle: 0, enabled: false },
      frame: frame,
    }
  }

  // Theme art for text buttons ([controls] button-frame, with the usual
  // frame keys, plus button-frame-hover and button-frame-pressed images for
  // those states). null when the theme sets none. state: "normal", "hover"
  // or "pressed".
  function buttonSpec(state) {
    var spec = frameOnlySpec("controls", "button-frame")
    if (!spec) return null
    var alt = state === "hover" ? image("controls", "button-frame-hover")
      : state === "pressed" ? image("controls", "button-frame-pressed")
      : ""
    if (alt.length > 0) {
      var frame = {}
      for (var k in spec.frame) frame[k] = spec.frame[k]
      frame.source = alt
      spec.frame = frame
    }
    return spec
  }

  function surfaceSpec(section, token, fallbackColor, fallbackWidth, alphaKey) {
    var opacity = alpha(section, alphaKey || token + "-alpha", 1.0)
    var legacyGradientRaw = valueOr(section, token === "border" ? ["border-gradient"] : [token + "-gradient", "border-gradient"])
    var resolved = borderValue(resolveValueRef(value(section, token)), fallbackColor, opacity, legacyGradientRaw)
    var frame = (token === "border" || token.indexOf("border-") === 0) ? frameSpec(section) : null

    return {
      color: resolved.color,
      widths: frame ? Geometry.parseWidthSpec(frame.inset, 0) : surfaceWidths(section, token, fallbackWidth),
      gradient: resolved.gradient,
      frame: frame,
    }
  }

  function hyprlandActiveSpec(fallbackColor, fallbackWidth) {
    var raw = value("hyprland", "active-border")
    var opacity = alpha("hyprland", "active-border-alpha", 1.0)

    // Existing generated themes predate [hyprland] and already keep the active
    // border under [notifications]. Use it as the compatibility source until
    // the next theme refresh writes the shared token.
    if (String(raw).length === 0) {
      raw = value("notifications", "border")
      opacity = alpha("notifications", "border-alpha", opacity)
    }

    var resolved = borderValue(resolveValueRef(raw), fallbackColor, opacity, "")
    return {
      color: resolved.color,
      widths: Geometry.parseWidthSpec(value("hyprland", "active-border-width"), fallbackWidth),
      gradient: resolved.gradient,
    }
  }

  function controlPrefix(state) {
    if (state === "hover" || state === "hot") return "hover-cursor"
    return state || "normal"
  }

  function controlColor(prefix, foreground, accent, urgent) {
    if (prefix === "focus") return Style.focusStateColor(foreground, accent, urgent)
    if (prefix === "hover-cursor") return Style.hoverStateColor(foreground, accent, urgent)
    if (prefix === "selected") return Style.selectedStateColor(foreground, accent, urgent)
    return Style.normalStateColor(foreground, accent, urgent)
  }

  function controlAlpha(prefix) {
    if (prefix === "focus") return Style.focusBorderAlpha
    if (prefix === "hover-cursor") return Style.hoverBorderAlpha
    if (prefix === "selected") return Style.selectedBorderAlpha
    return Style.normalBorderAlpha
  }

  function controlFallbackWidth(prefix) {
    if (prefix === "focus") return Style.focusBorderWidth
    if (prefix === "hover-cursor") return Style.hoverBorderWidth
    if (prefix === "selected") return Style.selectedBorderWidth
    return Style.normalBorderWidth
  }

  function controlWidths(state) {
    var prefix = controlPrefix(state)
    var fallbackWidth = controlFallbackWidth(prefix)
    var base = Style.styleOverrides[prefix + "-border-width"]
    var widths = Geometry.parseWidthSpec(base, fallbackWidth)
    return Geometry.withSideOverrides(
      widths,
      Style.styleOverrides[prefix + "-border-width-top"],
      Style.styleOverrides[prefix + "-border-width-right"],
      Style.styleOverrides[prefix + "-border-width-bottom"],
      Style.styleOverrides[prefix + "-border-width-left"]
    )
  }

  function controlHasWidth(state) {
    return Geometry.maxWidth(controlWidths(state)) > 0
  }

  function controlSpec(state, foreground, accent, urgent) {
    var prefix = controlPrefix(state)
    var resolved = borderValue(
      Style.styleOverrides[prefix + "-border"],
      controlColor(prefix, foreground, accent, urgent),
      controlAlpha(prefix),
      Style.styleOverrides[prefix + "-border-gradient"]
    )

    return { color: resolved.color, widths: controlWidths(prefix), gradient: resolved.gradient }
  }

  function withWidth(spec, width) {
    if (!spec) return flat("transparent", 0)
    return { color: spec.color, gradient: spec.gradient, widths: Geometry.parseWidthSpec(width, 0), frame: spec.frame }
  }

  function isNone(spec) { return !spec || Geometry.maxWidth(spec.widths) <= 0 }
  function hasFrame(spec) { return !!(spec && spec.frame) }
  // Vertical room an image frame takes. Surfaces sized from their content
  // add it: a frame inset is far thicker than the colour border their
  // height math was written for. 0 without a frame, so colour borders keep
  // their old sizes.
  function frameChrome(spec) { return hasFrame(spec) ? top(spec) + bottom(spec) : 0 }
  function needsOverlay(spec) { return hasFrame(spec) || Geometry.needsOverlay(spec) }
  function canUseNative(spec) { return !hasFrame(spec) && Geometry.canUseNative(spec) }
  function top(spec) { return spec && spec.widths ? spec.widths.top : 0 }
  function right(spec) { return spec && spec.widths ? spec.widths.right : 0 }
  function bottom(spec) { return spec && spec.widths ? spec.widths.bottom : 0 }
  function left(spec) { return spec && spec.widths ? spec.widths.left : 0 }
  function uniformWidth(spec) { return spec && spec.widths ? spec.widths.top : 0 }
  function color(spec) { return spec ? spec.color : "transparent" }
}
