// Draws the app icon, a moving box on a blue-green square, as a PNG.
// Usage: osascript -l JavaScript icon.js <out.png> [pixels]
ObjC.import("Cocoa");

function run(argv) {
  var out = argv[0], px = Number(argv[1] || 1024), s = px / 1024;
  var rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, px, px, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
  $.NSGraphicsContext.saveGraphicsState;
  $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));

  // macOS icon grid: an 824 pt rounded square centred on 1024, with a soft shadow
  var rect = $.NSMakeRect(100 * s, 100 * s, 824 * s, 824 * s);
  var shape = $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(rect, 185 * s, 185 * s);
  var shadow = $.NSShadow.alloc.init;
  shadow.shadowOffset = $.NSMakeSize(0, -10 * s);
  shadow.shadowBlurRadius = 24 * s;
  shadow.shadowColor = $.NSColor.colorWithSRGBRedGreenBlueAlpha(0, 0, 0, 0.3);
  $.NSGraphicsContext.saveGraphicsState;
  shadow.set;
  $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.16, 0.45, 0.93, 1).setFill;
  shape.fill;
  $.NSGraphicsContext.restoreGraphicsState;
  $.NSGradient.alloc.initWithStartingColorEndingColor(
    $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.13, 0.42, 0.95, 1),
    $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.10, 0.74, 0.68, 1)).drawInBezierPathAngle(shape, -65);

  var config = $.NSImageSymbolConfiguration.configurationWithPointSizeWeightScale(400 * s, $.NSFontWeightMedium, 3)  // 3: large scale, a constant JXA doesn't bridge
    .configurationByApplyingConfiguration($.NSImageSymbolConfiguration.configurationWithHierarchicalColor($.NSColor.whiteColor));
  var symbol = $.NSImage.imageWithSystemSymbolNameAccessibilityDescription("shippingbox.fill", "Moving box").imageWithSymbolConfiguration(config);
  var w = symbol.size.width, h = symbol.size.height;
  symbol.drawInRect($.NSMakeRect((px - w) / 2, (px - h) / 2 - 8 * s, w, h));

  $.NSGraphicsContext.restoreGraphicsState;
  rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSDictionary.dictionary).writeToFileAtomically(out, true);
  return out;
}
