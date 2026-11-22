// ClinicMD Astryx theme: neutral theme + the three agent tokens (DESIGN-DIRECTION §2).
// Nothing else is overridden. Noto Sans Devanagari follows Figtree so Nepali text has real glyphs.
import { defineTheme } from "@astryxdesign/core/theme";
import { neutralTheme } from "@astryxdesign/theme-neutral";

export const clinicTheme = defineTheme({
  name: "clinic",
  extends: neutralTheme,
  tokens: {
    "--color-agent": ["#7B2FF7", "#A878FF"],
    "--color-agent-muted": ["#F1EAFF", "#2A1850"],
    "--color-on-agent-muted": ["#5A1FCF", "#D9C6FF"],
  },
});
