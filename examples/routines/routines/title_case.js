if (s === null) {
  return null;
}
// Template literals are fine here: only *.tftpl files are template-rendered.
return s
  .toLowerCase()
  .split(/\s+/)
  .map((w) => `${w.charAt(0).toUpperCase()}${w.slice(1)}`)
  .join(" ");
