/* Omarchy Theme for KewkyFox
 *
 * KewkyFox loads this into its browser windows and reloads it when the theme
 * changes. A theme can ship its own kewkyfox.css to replace it, art included:
 * url() paths are relative to the theme directory. Rules apply under
 * :root[omarchy-theme], which KewkyFox sets while a theme sheet is loaded.
 */

:root[omarchy-theme] {
  color-scheme: {{ mode }} !important;

  --omarchy-background: {{ background }};
  --omarchy-dark-background: {{ dark_background }};
  --omarchy-lighter-background: {{ lighter_background }};
  --omarchy-foreground: {{ foreground }};
  --omarchy-dark-foreground: {{ dark_foreground }};
  --omarchy-accent: {{ accent }};
  --omarchy-muted: {{ muted }};
  --omarchy-selection: {{ selection_background }};

  /* Tab strip and title bar */
  --toolbox-background-color: {{ dark_background }} !important;
  --toolbox-background-color-inactive: {{ dark_background }} !important;
  --toolbox-text-color: {{ foreground }} !important;
  --toolbox-text-color-inactive: {{ dark_foreground }} !important;
  --tab-background-color-selected: {{ background }} !important;
  --tab-selected-textcolor: {{ foreground }} !important;
  --tab-selected-outline-color: {{ muted }} !important;
  --tab-background-color-hover: color-mix(in srgb, {{ foreground }} 10%, transparent) !important;
  --tab-loading-fill: {{ accent }} !important;
  --tabs-navbar-separator-color: {{ muted }} !important;

  /* Navigation toolbar and buttons */
  --toolbar-background-color: {{ background }} !important;
  --toolbar-text-color: {{ foreground }} !important;
  --toolbarseparator-color: {{ muted }} !important;
  --toolbarbutton-icon-fill: {{ foreground }} !important;
  --toolbarbutton-icon-fill-attention: {{ accent }} !important;
  --toolbarbutton-background-color-hover: color-mix(in srgb, {{ foreground }} 12%, transparent) !important;
  --toolbarbutton-background-color-active: color-mix(in srgb, {{ foreground }} 20%, transparent) !important;
  --chrome-content-separator-color: {{ muted }} !important;

  /* Address bar and its results */
  --toolbar-field-background-color: {{ lighter_background }} !important;
  --toolbar-field-text-color: {{ foreground }} !important;
  --toolbar-field-border-color: transparent !important;
  --toolbar-field-background-color-focus: {{ dark_background }} !important;
  --toolbar-field-text-color-focus: {{ foreground }} !important;
  --toolbar-field-border-color-focus: {{ accent }} !important;
  --urlbar-box-background-color: {{ lighter_background }} !important;
  --urlbar-box-background-color-hover: color-mix(in srgb, {{ foreground }} 14%, {{ lighter_background }}) !important;
  --urlbar-box-text-color: {{ foreground }} !important;
  --urlbarview-background-color-selected: {{ selection_background }} !important;
  --urlbarview-text-color-selected: {{ selection_foreground }} !important;
  --urlbarview-background-color-hover: color-mix(in srgb, {{ foreground }} 10%, transparent) !important;

  /* Menus, panels and popups */
  --panel-background-color: {{ background }} !important;
  --panel-text-color: {{ foreground }} !important;
  --panel-border-color: {{ muted }} !important;
  --panel-separator-color: {{ muted }} !important;

  /* Sidebar and the page area behind loading tabs */
  --sidebar-background-color: {{ dark_background }} !important;
  --sidebar-text-color: {{ foreground }} !important;
  --sidebar-border-color: {{ muted }} !important;
  --tabpanel-background-color: {{ background }} !important;

  /* Accents */
  --focus-outline-color: {{ accent }} !important;
  --color-accent-primary: {{ accent }} !important;
  --link-color: {{ blue }} !important;
  --input-bgcolor: {{ lighter_background }} !important;
  --input-color: {{ foreground }} !important;
}
