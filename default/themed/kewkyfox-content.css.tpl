/* Omarchy Theme for KewkyFox pages
 *
 * KewkyFox registers this for every page, so rules sit inside @-moz-document
 * like userContent.css. ../background is the current Omarchy wallpaper.
 * KewkyFox inlines the images it names: pages cannot read the theme
 * directory. A theme can ship its own kewkyfox-content.css to replace it.
 */

@-moz-document url-prefix("about:newtab"), url-prefix("about:home") {
  :root {
    color-scheme: {{ mode }} !important;
    --newtab-background-color: {{ background }} !important;
    --newtab-background-color-secondary: {{ lighter_background }} !important;
    --newtab-background-card: rgba({{ background_rgb }}, 0.88) !important;
    --newtab-text-primary-color: {{ foreground }} !important;
    --newtab-text-secondary-color: {{ dark_foreground }} !important;
    --newtab-element-hover-color: color-mix(in srgb, {{ foreground }} 12%, transparent) !important;
    --newtab-element-active-color: color-mix(in srgb, {{ foreground }} 20%, transparent) !important;
    --newtab-primary-action-background: {{ accent }} !important;
    --newtab-weather-background-color: rgba({{ background_rgb }}, 0.88) !important;
  }

  body {
    background:
      linear-gradient(rgba({{ background_rgb }}, 0.72), rgba({{ background_rgb }}, 0.72)),
      {{ background }} url("../background") center / cover fixed no-repeat !important;
  }
}
