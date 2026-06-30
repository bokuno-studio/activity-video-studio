# ActivityVideoStudio `.avstheme` format

`.avstheme` is a JSON file for ActivityVideoStudio overlay themes. The app can
read a theme from disk, select it in the overlay settings, write the selected
theme back to disk, and save imported user themes inside `.avsproj` projects.

## Top-level shape

```json
{
  "schemaVersion": 1,
  "id": "designer.neon-map-left",
  "name": "Neon Map Left",
  "style": {
    "accentColor": { "red": 1.0, "green": 0.52, "blue": 0.12, "alpha": 1.0 },
    "accentRed": { "red": 1.0, "green": 0.2, "blue": 0.15, "alpha": 1.0 },
    "shadowColor": { "red": 0.0, "green": 0.0, "blue": 0.0, "alpha": 0.76 },
    "metricsBackgroundColor": { "red": 0.0, "green": 0.0, "blue": 0.0, "alpha": 0.48 },
    "panelBackgroundColor": { "red": 0.0, "green": 0.0, "blue": 0.0, "alpha": 0.38 },
    "mapBackgroundColor": { "red": 0.0, "green": 0.0, "blue": 0.0, "alpha": 0.48 },
    "elevationColor": { "red": 0.35, "green": 0.86, "blue": 0.38, "alpha": 1.0 },
    "elevationLineColor": { "red": 0.35, "green": 0.86, "blue": 0.38, "alpha": 0.92 },
    "elevationFillColor": { "red": 0.35, "green": 0.86, "blue": 0.38, "alpha": 0.2 },
    "trackOutlineColor": { "red": 0.0, "green": 0.0, "blue": 0.0, "alpha": 0.56 },
    "trackLineColor": { "red": 0.0, "green": 0.84, "blue": 1.0, "alpha": 1.0 },
    "mapDotColor": { "red": 1.0, "green": 0.2, "blue": 0.15, "alpha": 1.0 },
    "labelFontSize": 24,
    "valueFontSize": 64,
    "distanceFontSize": 54,
    "leftXPosition": { "anchor": "left", "offset": 50 },
    "leftStartYPosition": { "anchor": "proportion", "fraction": 0.43, "offset": 0 },
    "rightXPosition": { "anchor": "right", "offset": 450 },
    "rightStartYPosition": { "anchor": "proportion", "fraction": 0.58, "offset": 0 },
    "leftMetricAdvance": -108,
    "rightDistanceAdvance": -98,
    "rightMetricAdvance": -108,
    "metricPanelWidthScale": 0.9,
    "distancePanelWidthScale": 0.9,
    "metricsCornerRadius": 8,
    "mapWidthRatio": 0.22,
    "mapHeightRatio": 0.28,
    "mapMargin": 20,
    "mapCornerRadius": 8,
    "mapPlacement": "topLeft",
    "profileGap": 12,
    "profileBottomPadding": 14,
    "profileCornerRadius": 6
  }
}
```

## Fields

- `schemaVersion`: integer format version. Current value is `1`.
- `id`: stable theme identifier. Use a reverse-DNS or namespaced value such as
  `designer.neon-map-left`. IDs beginning with `builtin.` are reserved by the
  app and are imported as user IDs.
- `name`: display name shown in the theme picker.
- `style`: render style values consumed by preview and export.

Colors are RGBA objects with `red`, `green`, `blue`, and `alpha` values from
`0.0` to `1.0`.

Horizontal positions use one of:

```json
{ "anchor": "left", "offset": 50 }
{ "anchor": "right", "offset": 450 }
{ "anchor": "proportion", "fraction": 0.5, "offset": 0 }
```

Vertical positions use one of:

```json
{ "anchor": "top", "offset": 50 }
{ "anchor": "bottom", "offset": 232 }
{ "anchor": "proportion", "fraction": 0.65, "offset": -130 }
```

Offsets and font sizes are authored against a 1920 px wide baseline and are
scaled by `videoWidth / 1920`. Ratio fields are fractions of the rendered video
size. `mapPlacement` is either `topLeft` or `topRight`.

## Built-in themes

The built-in themes are generated from the same render-style model and can be
exported from the app as `.avstheme` files:

- `builtin.default`
- `builtin.compact`
- `builtin.highContrast`
- `builtin.lowerThird`
- `builtin.mapLeft`
