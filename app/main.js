// Mac Migrate: native windows for backup.sh, restore.sh and cleanup.sh.
// make-app.sh compiles this file into an app with osacompile and puts the scripts in
// Contents/Resources/engine. The scripts do the work; this file asks the questions and shows progress.
//   osascript -l JavaScript app/main.js --self-test [engine-folder]   checks the parts that need no window
ObjC.import("Cocoa");

var SA = Application.currentApplication();
SA.includeStandardAdditions = true;
var HOME = ObjC.unwrap($.NSHomeDirectory());
var STATE = HOME + "/.mac-migration";
var RUN = STATE + "/run/app";
var ENGINE = "";
var WIDTH = 440;
var GITHUB = "https://github.com/nikolavas/mac-migrate";

// ---------------------------------------------------------------------------
// Parsing and wording, no windows (covered by --self-test)

function rows(text) {
  return String(text || "").split("\n").filter(function (l) { return l.length > 0; }).map(function (l) { return l.split("\t"); });
}

function size(kb) {
  kb = Number(kb) || 0;
  if (kb < 1024) return Math.round(kb) + " KB";
  if (kb < 1048576) return Math.round(kb / 1024) + " MB";
  if (kb < 1048576 * 100) return (kb / 1048576).toFixed(1) + " GB";
  return Math.round(kb / 1048576) + " GB";
}

function timeLeft(sec) {
  sec = Number(sec);
  if (!(sec >= 0)) return "";
  var m = Math.round(sec / 60);
  if (m < 1) return "less than a minute left";
  if (m < 60) return "about " + m + " min left";
  return "about " + Math.floor(m / 60) + " h " + ("0" + (m % 60)).slice(-2) + " min left";
}

// status: phase item done_kb total_kb rate_kb_s eta_s message
function parseStatus(text) {
  var r = rows(text)[0];
  if (!r) return null;
  return { phase: r[0], item: r[1] || "", done: Number(r[2]) || 0, total: Number(r[3]) || 0,
    rate: Number(r[4]) || 0, eta: r[5] === undefined || r[5] === "" ? -1 : Number(r[5]), message: r[6] || "" };
}

var VERBS = { pack: "Packing", verify: "Checking", upload: "Uploading", measure: "Measuring folders", unpack: "Unpacking",
  download: "Downloading", clean: "Cleaning", done: "Finishing" };

// Two lines and a fraction (-1 when unknown) for the progress window
function describe(s) {
  if (!s) return { title: "Starting…", detail: "", fraction: -1 };
  var bytes = s.phase === "pack" || s.phase === "unpack";
  var title = s.message || ((VERBS[s.phase] || s.phase) + (s.item ? " " + s.item : "") + "…");
  var parts = [];
  if (bytes && s.total > 0) parts.push(size(s.done) + " of " + size(s.total));
  if (bytes && s.rate > 0) parts.push(Math.round(s.rate / 1024) + " MB/s");
  if (bytes && s.eta >= 0) parts.push(timeLeft(s.eta));
  var fraction = (bytes || s.phase === "done") && s.total > 0 ? Math.min(1, s.done / s.total) : -1;
  return { title: title, detail: parts.join(" · "), fraction: fraction };
}

function parseEvents(text) {
  var ev = { result: null, warnings: [], files: [], log: "", done: "", folder: "", mode: "", provider: "", restore: "" };
  rows(text).forEach(function (r) {
    switch (r[0]) {
      case "result": ev.result = { code: Number(r[1]), reason: r[2] || "" }; break;
      case "warn": ev.warnings.push(r[1]); break;
      case "file": ev.files.push(r[1]); break;
      case "log": case "done": case "folder": case "mode": case "provider": case "restore": ev[r[0]] = r[1] || ""; break;
    }
  });
  return ev;
}

function parsePlaces(text) {
  return rows(text).map(function (r) {
    return { id: r[0], kind: r[1], label: r[2], path: r[3], freeKb: Number(r[4]) || 0, fs: r[5] || "", partMb: r[6] || "", note: r[7] || "" };
  });
}

function parseSources(text) {
  return rows(text).map(function (r) { return { kind: r[0], item: r[1], kb: Number(r[2]) || 0, on: r[3] === "1", note: r[4] || "" }; });
}

function parseCleanup(text) {
  return rows(text).map(function (r) { return { id: r[0], label: r[1], kb: Number(r[2]) || 0, tier: r[3], on: r[4] === "1", note: r[5] || "" }; });
}

// key<TAB>value lines and repeated "archive" lines, from backup.sh --status and restore.sh --plan
function parseReport(text) {
  var rep = { archives: [], aside: [], merge: [] };
  rows(text).forEach(function (r) {
    if (r[0] === "archive") rep.archives.push({ name: r[1], state: r[2], kb: Number(r[3]) || 0 });
    else if (r[0] === "aside" || r[0] === "merge") rep[r[0]].push(r[1]);
    else rep[r[0]] = r[1];
  });
  return rep;
}

function placeDetail(p) {
  var d = size(p.freeKb) + " free";
  if (p.kind === "cloud") d += " on this Mac · each archive moves there and is freed here once uploaded";
  if (p.kind === "disk") d += " · written straight to the disk";
  return d + (p.note ? "\n" + p.note : "");
}

function tilde(path) { return path.indexOf(HOME + "/") === 0 ? "~" + path.slice(HOME.length) : path; }

// ---------------------------------------------------------------------------
// Files and processes

function fm() { return $.NSFileManager.defaultManager; }
function readFile(p) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null);
  return s.isNil() ? "" : ObjC.unwrap(s);
}
function writeFile(p, text) { $(text).writeToFileAtomicallyEncodingError(p, true, $.NSUTF8StringEncoding, null); }
function exists(p) { return fm().fileExistsAtPath(p); }
function mkdirs(p) { fm().createDirectoryAtPathWithIntermediateDirectoriesAttributesError(p, true, $(), null); }
function remove(p) { fm().removeItemAtPathError(p, null); }
function q(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
function sh(cmd) { try { return SA.doShellScript(cmd); } catch (e) { return ""; } }
function lastLines(p, n) { return readFile(p).trim().split("\n").slice(-(n || 3)).join("\n"); }

// Starts an engine script in its own process group, so Stop can end tar, gzip and openssl too.
// Output goes to files, never to a pipe, so the script keeps going if this app quits.
function start(script, args, opts) {
  opts = opts || {};
  mkdirs(RUN);
  ["status", "events.tsv"].forEach(function (f) { remove(RUN + "/" + f); });
  writeFile(RUN + "/engine.out", "");
  writeFile(RUN + "/out.tsv", "");
  var t = $.NSTask.alloc.init;
  t.launchPath = "/usr/bin/perl";
  var a = ["-e", "setpgrp(0,0); exec @ARGV", "/bin/bash", ENGINE + "/" + script].concat(args || []);
  if (opts.password !== undefined) a.push("--password-stdin");
  t.arguments = $(a);
  var env = $.NSMutableDictionary.dictionaryWithDictionary($.NSProcessInfo.processInfo.environment);
  var add = { MIG_NONINTERACTIVE: "1", MIG_RUN: RUN };
  Object.keys(opts.env || {}).forEach(function (k) { add[k] = opts.env[k]; });
  Object.keys(add).forEach(function (k) { env.setObjectForKey($(String(add[k])), $(k)); });
  t.environment = env;
  t.standardOutput = $.NSFileHandle.fileHandleForWritingAtPath(RUN + (opts.capture ? "/out.tsv" : "/engine.out"));
  t.standardError = $.NSFileHandle.fileHandleForWritingAtPath(RUN + "/engine.out");
  var pipe = $.NSPipe.pipe;
  t.standardInput = pipe;
  t.launch;
  var w = pipe.fileHandleForWriting;
  if (opts.password !== undefined) w.writeData($(opts.password + "\n").dataUsingEncoding($.NSUTF8StringEncoding));
  w.closeFile;
  return t;
}

function alive(task, pid) {
  if (task) return task.running;
  return sh("ps -o pid= -p " + pid).trim() !== "";
}

// delay() throws when Stop is clicked in the progress window. Where that click means nothing, wait anyway.
function pause(sec) { try { delay(sec); } catch (e) { $.NSThread.sleepForTimeInterval(sec); } }

// TERM to the whole process group, KILL after 10 seconds
function stop(pid) {
  var group = sh("ps -o pgid= -p " + pid).trim() === String(pid);
  var target = group ? "-" + pid : String(pid);
  sh("/bin/kill -TERM -- " + target);
  for (var i = 0; i < 20 && alive(null, pid); i++) pause(0.5);
  if (alive(null, pid)) sh("/bin/kill -KILL -- " + target);
}

var HAS_PROGRESS = typeof Progress !== "undefined";
function progress(title, detail, fraction) {
  if (!HAS_PROGRESS) return;
  Progress.description = title;
  Progress.additionalDescription = detail || "";
  if (fraction >= 0) { Progress.totalUnitCount = 1000; Progress.completedUnitCount = Math.round(fraction * 1000); }
  else { Progress.totalUnitCount = -1; }
}
function progressDone() { if (HAS_PROGRESS) { Progress.totalUnitCount = 0; Progress.completedUnitCount = 0; Progress.description = ""; Progress.additionalDescription = ""; } }

// Shows progress until the engine ends. task is null when attaching to a run started earlier.
function monitor(task, what, pid, askStop) {
  pid = pid || task.processIdentifier;
  progress(what, "Starting…", -1);
  var stopping = false, asked = 0;
  while (alive(task, pid)) {
    try {
      delay(0.5);
    } catch (e) {
      // Stop in the progress window. Ask at most every 3 seconds, in case the click keeps firing.
      if (stopping || Date.now() - asked < 3000) { $.NSThread.sleepForTimeInterval(0.5); continue; }
      if (!askStop || askStop()) { stopping = true; progress("Stopping…", "", -1); stop(pid); }
      asked = Date.now();
      continue;
    }
    var d = describe(parseStatus(readFile(RUN + "/status")));
    progress(d.title, d.detail, d.fraction);
  }
  progressDone();
  var ev = parseEvents(readFile(RUN + "/events.tsv"));
  // no result line when the engine was stopped before it set its traps: a signal N counts as 128 + N, like in a shell
  var code = ev.result ? ev.result.code : !task ? 1 :
    Number(task.terminationReason) === 2 ? 128 + Number(task.terminationStatus) : Number(task.terminationStatus);
  var reason = ev.result && ev.result.reason ? ev.result.reason : lastLines(RUN + "/engine.out");
  return { code: code, reason: reason, events: ev, out: readFile(RUN + "/out.tsv") };
}

function run_(script, args, what, opts) {
  try {
    return monitor(start(script, args, opts), what, null, opts && opts.askStop);
  } catch (e) {
    return { code: 1, reason: "Couldn't start " + script + ": " + e, events: parseEvents(""), out: "" };
  }
}

// ---------------------------------------------------------------------------
// Windows

ObjC.registerSubclass({
  name: "MMTarget",
  methods: { "changed:": { types: ["void", ["id"]], implementation: function (sender) { if (FORM && FORM.changed) FORM.changed(sender); } } },
});
var FORM = null, TARGET = null;
function target() { if (!TARGET) TARGET = $.MMTarget.alloc.init; return TARGET; }

function activate() { $.NSApplication.sharedApplication.activateIgnoringOtherApps(true); }

function label(text, opts) {
  opts = opts || {};
  var l = $.NSTextField.wrappingLabelWithString(text);
  if (opts.small) { l.font = $.NSFont.systemFontOfSize($.NSFont.smallSystemFontSize); l.textColor = $.NSColor.secondaryLabelColor; }
  if (opts.bold) l.font = $.NSFont.boldSystemFontOfSize($.NSFont.systemFontSize);
  if (opts.mono) { l.font = $.NSFont.monospacedSystemFontOfSizeWeight($.NSFont.smallSystemFontSize, 0); l.selectable = true; }
  l.preferredMaxLayoutWidth = opts.width || WIDTH;
  return l;
}

function vstack(views, spacing, inset) {
  var s = $.NSStackView.alloc.initWithFrame($.NSMakeRect(0, 0, WIDTH, 10));
  s.orientation = $.NSUserInterfaceLayoutOrientationVertical;
  s.alignment = $.NSLayoutAttributeLeading;
  s.spacing = spacing === undefined ? 8 : spacing;
  if (inset) s.edgeInsets = $.NSEdgeInsetsMake(0, inset, 0, 0);
  views.forEach(function (v) { s.addArrangedSubview(v); });
  return s;
}

// Sizes a view to its content, in a scroll view when taller than max
function fit(view, max) {
  var h = view.fittingSize.height;
  view.setFrameSize($.NSMakeSize(WIDTH, h));
  if (!max || h <= max) return view;
  var sv = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(0, 0, WIDTH + 16, max));
  sv.hasVerticalScroller = true;
  sv.drawsBackground = false;
  sv.documentView = view;
  if (!view.isFlipped) view.scrollPoint($.NSMakePoint(0, h));
  return sv;
}

function alertWith(title, message, buttons, accessory, warning) {
  activate();
  var a = $.NSAlert.alloc.init;
  a.messageText = title;
  a.informativeText = message || "";
  if (warning) a.alertStyle = $.NSAlertStyleWarning;
  (buttons || ["OK"]).forEach(function (b) { a.addButtonWithTitle(b); });
  if (accessory) a.accessoryView = accessory;
  if (SHOT_ICON) a.icon = SHOT_ICON;
  a.layout;
  return a;
}

// Returns the index of the button clicked, 0 for the first. With SHOT set, saves a picture of the
// window instead and returns -1 (for --screenshots).
var SHOT = null, SHOT_DARK = false, SHOT_ICON = null;
function show(a, focus) {
  if (SHOT) { render(a, SHOT); SHOT = null; return -1; }
  if (focus) a.window.initialFirstResponder = focus;
  return Number(a.runModal) - 1000;
}

// The alert drawn on a plain rounded background: offscreen, the window's glass background isn't drawn
function render(a, path) {
  var w = a.window;
  w.appearance = $.NSAppearance.appearanceNamed(SHOT_DARK ? "NSAppearanceNameDarkAqua" : "NSAppearanceNameAqua");
  var v = w.contentView;
  v.layoutSubtreeIfNeeded;
  var b = v.bounds, content = v.bitmapImageRepForCachingDisplayInRect(b);
  v.cacheDisplayInRectToBitmapImageRep(b, content);
  var out = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, content.pixelsWide, content.pixelsHigh, 8, 4, true, false, $.NSDeviceRGBColorSpace, 0, 0);
  out.size = b.size;
  $.NSGraphicsContext.saveGraphicsState;
  $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(out));
  var shape = $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(0.5, 0.5, b.size.width - 1, b.size.height - 1), 18, 18);
  var g = SHOT_DARK ? 0.17 : 0.97;
  $.NSColor.colorWithSRGBRedGreenBlueAlpha(g, g, g, 1).setFill;
  shape.fill;
  $.NSColor.colorWithSRGBRedGreenBlueAlpha(0.5, 0.5, 0.5, 0.35).setStroke;
  shape.stroke;
  // as an NSImage: an image rep draws with "copy" and would wipe the background
  var img = $.NSImage.alloc.initWithSize(b.size);
  img.addRepresentation(content);
  img.drawInRect($.NSMakeRect(0, 0, b.size.width, b.size.height));
  $.NSGraphicsContext.restoreGraphicsState;
  out.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSDictionary.dictionary).writeToFileAtomically(path, true);
}

function info(title, message, buttons, warning, extra) {
  return show(alertWith(title, message, buttons, extra ? fit(vstack(extra, 6)) : null, warning));
}

function confirm(title, message, yes, no) { return info(title, message, [yes || "Continue", no || "Cancel"]) === 0; }

// One choice from a list. options: {label, detail}. Returns {button, index}.
function choose(title, message, options, selected, buttons) {
  var radios = [];
  var views = options.map(function (o, i) {
    var b = $.NSButton.radioButtonWithTitleTargetAction(o.label, target(), "changed:");
    b.state = i === (selected || 0) ? 1 : 0;
    radios.push(b);
    return o.detail ? vstack([b, vstack([label(o.detail, { small: true, width: WIDTH - 24 })], 0, 20)], 2) : b;
  });
  FORM = { changed: function (sender) { radios.forEach(function (b) { b.state = b.isEqual(sender) ? 1 : 0; }); } };
  var r = show(alertWith(title, message, buttons || ["Continue", "Cancel"], fit(vstack(views, 10), 400)));
  FORM = null;
  var index = -1;
  radios.forEach(function (b, i) { if (Number(b.state) === 1) index = i; });
  return { button: r, index: r === 0 ? index : -1 };
}

// Several choices. groups: [{heading, items: [{label, kb, on, detail, locked}]}]. summary(checked) fills the line below.
function checklist(title, message, groups, buttons, summary) {
  var boxes = [], items = [], views = [];
  var total = label(" ", { small: true });
  groups.forEach(function (g) {
    if (!g.items.length) return;
    if (g.heading) views.push(label(g.heading, { bold: true }));
    g.items.forEach(function (it) {
      var b = $.NSButton.checkboxWithTitleTargetAction(it.label + (it.kb !== undefined ? "   " + size(it.kb) : ""), target(), "changed:");
      b.state = it.on ? 1 : 0;
      if (it.locked) b.enabled = false;
      boxes.push(b); items.push(it);
      views.push(it.detail ? vstack([b, vstack([label(it.detail, { small: true, width: WIDTH - 24 })], 0, 20)], 2) : b);
    });
  });
  function checked() { return items.filter(function (it, i) { return Number(boxes[i].state) === 1; }); }
  function update() { if (summary) total.stringValue = summary(checked()); }
  FORM = { changed: update };
  update();
  var r = show(alertWith(title, message, buttons || ["Continue", "Cancel"], fit(vstack([fit(vstack(views, 8), 380), total], 12))));
  FORM = null;
  return { button: r, items: r === 0 ? checked() : [] };
}

function secureField(placeholder) {
  var f = $.NSSecureTextField.alloc.initWithFrame($.NSMakeRect(0, 0, 300, 24));
  f.placeholderString = placeholder;
  f.widthAnchor.constraintEqualToConstant(300).active = true;
  return f;
}

// Asks for a password, twice for a new one. Returns null on Cancel.
function password(title, message, twice) {
  var f1 = secureField("Password"), f2 = twice ? secureField("Repeat the password") : null;
  var a = alertWith(title, message, ["Continue", "Cancel"], fit(vstack(f2 ? [f1, f2] : [f1], 8)));
  for (;;) {
    if (show(a, f1) !== 0) return null;
    var p = ObjC.unwrap(f1.stringValue);
    if (!p) { a.informativeText = message + "\n\nThe password is empty."; continue; }
    if (f2 && p !== ObjC.unwrap(f2.stringValue)) {
      a.informativeText = message + "\n\nThe passwords don't match.";
      f2.stringValue = "";
      continue;
    }
    return p;
  }
}

function chooseFolder(prompt, start) {
  try {
    var opts = { withPrompt: prompt };
    if (start && exists(start)) opts.defaultLocation = Path(start);
    return SA.chooseFolder(opts).toString();
  } catch (e) { return null; }
}

function openPrivacy() { sh("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders'"); }
function openLogs() { mkdirs(STATE + "/logs"); sh("open " + q(STATE + "/logs")); }

// Generic answer to an engine failure. Returns true when it was handled.
function explainFailure(res, what) {
  if (res.code === 130 || res.code === 143) {
    info(what + " stopped", "Start it again to continue where it stopped: finished archives are kept.");
    return true;
  }
  if (res.code === 12) {
    if (info("Mac Migrate needs access to your folders", res.reason + "\n\nTurn on Mac Migrate under Files and Folders (or Full Disk Access), then start again.",
      ["Open Privacy Settings", "Close"], true) === 0) openPrivacy();
    return true;
  }
  if (res.code === 13) { info("Mac Migrate is already running", res.reason); return true; }
  if (res.code === 15) { info("The upload has stalled", res.reason, ["OK"], true); return true; }
  var b = info(what + " didn't finish", res.reason || "Something went wrong.", ["Open the log", "Close"], true);
  if (b === 0) openLogs();
  return true;
}

// ---------------------------------------------------------------------------
// Back up

function backup() {
  if (sh("pmset -g batt").indexOf("Battery Power") >= 0 &&
    !confirm("Plug in your Mac", "A backup can take hours. On battery, your Mac may sleep and pause it. Keep the lid open, too.", "Continue anyway", "Cancel")) return;
  // ask for folder access now, not halfway through the backup
  sh("ls ~/Desktop ~/Documents ~/Downloads >/dev/null 2>&1");

  var res = run_("backup.sh", ["--list-places"], "Looking for cloud drives and disks…", { capture: true });
  var places = parsePlaces(res.out).filter(function (p) { return p.kind !== "local"; });
  var local = parsePlaces(res.out).filter(function (p) { return p.kind === "local"; })[0];
  var options = places.map(function (p) { return { label: p.label, detail: placeDetail(p) }; });
  options.push({ label: "Another folder…", detail: "A network share, or a folder you choose" });
  if (local) options.push({ label: local.label, detail: size(local.freeKb) + " free · " + local.note });
  var c = choose("Where should the backup go?",
    "Everything is encrypted with a password you choose before it leaves this Mac.", options, 0);
  if (c.button !== 0 || c.index < 0) return;
  var dest = null, destLabel;
  if (c.index < places.length) { dest = places[c.index].path; destLabel = places[c.index].label; }
  else if (c.index === places.length) {
    dest = chooseFolder("Choose a folder for the backup:");
    if (!dest) return;
    destLabel = tilde(dest);
  } else destLabel = "~/mac-migration-archives";
  var to = dest ? ["--to", dest] : [];

  res = run_("backup.sh", ["--status"].concat(to), "Looking for an earlier backup…", { capture: true });
  var existing = res.out.trim() === "none" || res.code !== 0 ? null : parseReport(res.out);
  if (existing && existing.archives.length) {
    var doneCount = existing.archives.filter(function (a) { return a.state === "done"; }).length;
    if (existing.complete === "yes") {
      // a new backup goes into a new folder next to the old one, except in ~/mac-migration-archives
      var b = info("This Mac is already backed up there", "The backup in " + tilde(existing.folder) + " has " + doneCount + " archives. " +
        (dest ? "Add folders to it, or make a new backup next to it." : "Add folders to it. To start over, move that folder away first."),
        dest ? ["Add folders…", "New backup", "Cancel"] : ["Add folders…", "Cancel"]);
      if (!dest && b === 1) return;
      if (b === 0) return addFolders(to, existing);
      if (b !== 1) return;
    } else {
      var b2 = info("Continue the backup?",
        doneCount + " of " + existing.archives.length + " archives in " + tilde(existing.folder) + " are done. The backup continues with the rest.",
        ["Continue", "Add folders…", "Cancel"]);
      if (b2 === 1) return addFolders(to, existing);
      if (b2 !== 0) return;
      return runBackup(to, null, destLabel, false);
    }
  }

  res = run_("backup.sh", ["--list-sources"], "Measuring your folders…", { capture: true });
  if (res.code !== 0) return explainFailure(res, "Measuring");
  var sources = parseSources(res.out);
  var groups = [
    { heading: "Always included", items: sources.filter(function (s) { return s.kind === "settings"; })
      .map(function (s) { return { label: "Settings, keys and tools", kb: s.kb, on: true, locked: true, detail: s.note, src: s }; }) },
    { heading: "Projects", items: sources.filter(function (s) { return s.kind === "projects"; })
      .map(function (s) { return { label: "~/" + s.item, kb: s.kb, on: s.on, detail: s.note, src: s }; }) },
    { heading: "Folders in your home folder", items: sources.filter(function (s) { return s.kind === "folder"; })
      .map(function (s) { return { label: "~/" + s.item, kb: s.note ? undefined : s.kb, on: s.on && !s.note, locked: !!s.note, detail: s.note, src: s }; }) },
  ];
  var free = dest ? (places[c.index] ? places[c.index].freeKb : 0) : (local ? local.freeKb : 0);
  var cloud = !!(places[c.index] && places[c.index].kind === "cloud");
  var pick = checklist("What should go into the backup?",
    "node_modules, virtual environments and similar folders are left out: you reinstall them per project.", groups,
    ["Continue", "Free up space…", "Cancel"],
    function (items) {
      var kb = items.reduce(function (t, it) { return t + it.kb; }, 0);
      var line = "Selected: " + size(kb) + " before compression · " + size(free) + " free";
      if (cloud) line += " here (archives up to 8 GB are packed here, one at a time)";
      else if (kb > free) line += ". That isn't enough: free up space or choose another place.";
      return line;
    });
  if (pick.button === 1) { cleanup(); return; }
  if (pick.button !== 0) return;
  var personal = [], roots = [];
  pick.items.forEach(function (it) {
    if (it.src.kind === "projects") roots.push(it.src.item);
    if (it.src.kind === "folder") personal.push(it.src.item);
  });
  return runBackup(to, { MIG_PERSONAL_ITEMS: personal.join("\n"), MIG_PROJECT_ROOTS: roots.join("\n") }, destLabel, true);
}

function addFolders(to, existing) {
  var res = run_("backup.sh", ["--list-sources"], "Measuring your folders…", { capture: true });
  var folders = parseSources(res.out).filter(function (s) { return s.kind === "folder" && !s.note; });
  var pick = checklist("Which folders should be added?",
    "Each one becomes an extra archive in " + tilde(existing.folder) + ". Folders already in the backup are skipped.",
    [{ items: folders.map(function (s) { return { label: "~/" + s.item, kb: s.kb, on: false, src: s }; }) }], ["Add", "Cancel"],
    function (items) { return "Selected: " + size(items.reduce(function (t, it) { return t + it.kb; }, 0)); });
  if (pick.button !== 0 || !pick.items.length) return;
  var add = ["--add"].concat(pick.items.map(function (it) { return it.src.item; }));
  return runBackup(to.concat(add), null, tilde(existing.folder), false);
}

function runBackup(args, env, destLabel, isNew) {
  var pw = password(isNew ? "Choose a password for the backup" : "Enter the backup's password",
    isNew ? "Save it in your password manager now. Without it nobody can open the archives, including you." :
      "The password you chose when this backup started.", isNew);
  if (pw === null) return;
  var extra = [];
  for (;;) {
    var res = run_("backup.sh", args.concat(extra), "Backing up to " + destLabel, { password: pw, env: env || {}, askStop: askStopBackup });
    if (res.code === 0) return backupDone(res.events);
    if (res.code === 10) {
      pw = password("That isn't the backup's password", "Enter the password you chose when this backup started.", false);
      if (pw === null) return;
      continue;
    }
    if (res.code === 11) {
      var files = res.events.files.map(tilde).join("\n");
      if (info("The disk is nearly full", "Copy these finished archives to your cloud drive or disk. When every copy is complete, click Continue: they are then deleted here to make room.\n\n" + files,
        ["Continue", "Stop"], true) !== 0) return;
      extra = ["--uploaded"];
      continue;
    }
    if (res.code === 14) {
      var b = info("Not enough space", res.reason, ["Free up space…", "Close"], true);
      if (b === 0) { cleanup(); if (confirm("Continue the backup?", "It continues where it stopped.")) { extra = []; continue; } }
      return;
    }
    return explainFailure(res, "The backup");
  }
}

function askStopBackup() {
  return confirm("Stop the backup?", "Finished archives are kept. Start the backup again later to continue where it stopped.", "Stop", "Keep going");
}

function backupDone(ev) {
  var cmd = ev.restore || "";
  var what = ev.done ? ev.done.replace(/ in .*$/, "") : "The backup is done";
  var where = ev.folder ? ev.folder.split("/").pop() + (ev.provider ? " on " + ev.provider : "") : "";
  var msg = what + (where ? " in " + where : "") + ".\n\n";
  if (ev.mode === "cloud") msg += "Everything is uploaded to " + (ev.provider || "the cloud drive") + ". On the new Mac, sign in to it, then run this in Terminal:";
  else if (ev.mode === "folder") msg += "Eject the disk before you unplug it. On the new Mac, connect it and run this in Terminal:";
  else msg += "Copy that folder to your cloud drive or a disk. On the new Mac, put it back and run its restore.sh in Terminal, for example:";
  var extra = [label(cmd, { mono: true })];
  if (ev.warnings.length) extra.push(label("Worth a look:\n• " + ev.warnings.slice(-5).join("\n• "), { small: true }));
  extra.push(label("Or use this app there too: download mac-migrate from " + GITHUB + " and run make-app.sh. Keep this Mac as it is until the new one works.", { small: true }));
  var b = info("Backup done", msg, ["Done", "Copy the command", "Show in Finder"], false, extra);
  if (b === 1) SA.setTheClipboardTo(cmd);
  if (b === 2 && ev.folder) sh("open -R " + q(ev.folder));
}

// ---------------------------------------------------------------------------
// Restore

function findBackups() {
  var roots = [HOME + "/Library/CloudStorage", HOME + "/Library/Mobile Documents/com~apple~CloudDocs", "/Volumes",
    HOME + "/Downloads", HOME + "/Desktop", HOME + "/Documents"];
  var found = sh("for r in " + roots.map(q).join(" ") + "; do [ -d \"$r\" ] && find \"$r\" -maxdepth 4 -name MANIFEST.txt " +
    "-not -path '*/mac-migrate/*' 2>/dev/null; done | sed 's#/MANIFEST.txt$##' | sort -u");
  return found.split("\r").join("\n").split("\n").filter(function (l) { return l; });
}

function restore() {
  progress("Looking for backups…", "In your cloud drives, disks, Downloads, Desktop and Documents", -1);
  var found = findBackups();
  progressDone();
  var options = found.map(function (f) { return { label: f.split("/").pop(), detail: tilde(f) }; });
  options.push({ label: "Choose a folder…", detail: "The folder with MANIFEST.txt and the archives" });
  var c = choose("Which backup should be restored?", found.length ? "Backups found on this Mac:" :
    "No backup found yet. Sign in to the cloud drive with your backup, or connect the disk, or choose the folder.", options, 0);
  if (c.button !== 0 || c.index < 0) return;
  var src = c.index < found.length ? found[c.index] : chooseFolder("Choose the backup folder:", HOME + "/Downloads");
  if (!src) return;

  var res = run_("restore.sh", ["--plan", "--from", src], "Reading the backup…", { capture: true });
  if (res.code !== 0) return explainFailure(res, "Reading the backup");
  var plan = parseReport(res.out);
  var pending = plan.archives.filter(function (a) { return a.state === "pending"; });
  var missing = plan.archives.filter(function (a) { return a.state === "missing"; });
  if (!pending.length) {
    info("Nothing new to restore", missing.length ? "These archives aren't in the folder (yet): " + missing.map(function (a) { return a.name; }).join(", ") :
      "Every archive in this backup is already restored.");
    return;
  }
  for (;;) {
    res = run_("restore.sh", ["--plan", "--from", src], "Reading the backup…", { capture: true });
    if (parseReport(res.out).claude !== "running") break;
    if (!confirm("Quit Claude Code first", "This restore brings back ~/.claude and ~/.claude.json, which Claude Code rewrites while it runs. Quit it, then click Continue.")) return;
  }
  var kb = pending.reduce(function (t, a) { return t + a.kb; }, 0);
  var lines = ["Restores " + pending.length + " archive(s), " + size(kb) + ", into your home folder. " + size(Number(plan.free_kb)) + " is free."];
  if (plan.aside.length) lines.push("These exist already and are moved to ~/.mac-migration-restore first: " + plan.aside.slice(0, 8).join(", ") + (plan.aside.length > 8 ? ", …" : "") + ".");
  if (plan.merge.length) lines.push("These folders are merged, files you have here stay: " + plan.merge.join(", ") + ".");
  if (missing.length) lines.push("Not in the folder yet, restore them later: " + missing.map(function (a) { return a.name; }).join(", ") + ".");
  if (plan.complete === "no") lines.push("The backup wasn't finished on the old Mac.");
  var env = {};
  if (plan.format === "1") {
    if (!confirm("This backup was made by mac-migrate 1", "Its files can't be checked for changes made after the backup. Restore it anyway?", "Restore anyway")) return;
    env.MIG_ALLOW_UNSIGNED = "1";
  }
  if (!confirm("Restore this backup?", lines.join("\n\n"), "Restore")) return;
  var pw = password("Enter the backup's password", "The password you chose on the old Mac.", false);
  for (;;) {
    if (pw === null) return;
    res = run_("restore.sh", ["--from", src], "Restoring", { password: pw, env: env, askStop: function () {
      return confirm("Stop the restore?", "Archives already restored stay. Start the restore again to continue.", "Stop", "Keep going");
    } });
    if (res.code !== 10) break;
    pw = password("Wrong password", "Enter the password you chose on the old Mac.", false);
  }
  if (res.code === 14) return info("Not enough space", res.reason + "\n\nFree up space, then start the restore again: it continues with what is left.", ["OK"], true);
  if (res.code !== 0) return explainFailure(res, "The restore");
  restoreDone();
}

function restoreDone() {
  var setup = STATE + "/new-mac-setup/setup.sh";
  var buttons = ["Done", "Show the inventory"];
  if (exists(setup)) buttons.unshift("Install apps and tools");
  var b = info("Your files are back",
    "Next:\n• Open a new Terminal window so your shell settings load.\n• Install your apps and tools: Homebrew asks for an administrator password once.\n" +
    "• Sign in again to tools that keep tokens in the Keychain (gh, gcloud, az, aws sso) and to your browsers.\n" +
    "• Reinstall project dependencies (npm install, uv sync) when you open a project.\n\nFiles the restore moved aside are in ~/.mac-migration-restore.", buttons);
  if (buttons[b] === "Install apps and tools") sh("open -a Terminal " + q(setup));
  if (buttons[b] === "Show the inventory") sh("open -e " + q(STATE + "/inventory.md"));
}

// ---------------------------------------------------------------------------
// Free up space

function cleanup() {
  var res = run_("cleanup.sh", ["--list"], "Measuring caches…", { capture: true });
  if (res.code !== 0) return explainFailure(res, "Measuring caches");
  var items = parseCleanup(res.out);
  if (!items.length) return info("Nothing to clean", "No caches worth clearing were found.");
  function group(tier, heading) {
    return { heading: heading, items: items.filter(function (i) { return i.tier === tier; }).map(function (i) {
      return { label: i.label, kb: i.kb, on: i.on, detail: i.note, src: i };
    }) };
  }
  var pick = checklist("Free up space", "Only caches and build output that tools recreate are listed. The first group is safe to clear any time.", [
    group("safe", "Rebuilt automatically"),
    group("download", "Downloaded again when needed: big, and slow to get back"),
    group("projects", "In your projects: the backup leaves these out anyway"),
  ], ["Clean", "Cancel"], function (sel) {
    return "Selected: " + size(sel.reduce(function (t, i) { return t + i.kb; }, 0));
  });
  if (pick.button !== 0 || !pick.items.length) return;
  res = run_("cleanup.sh", ["--clean"].concat(pick.items.map(function (i) { return i.src.id; })), "Freeing up space…", {});
  if (res.code !== 0) return explainFailure(res, "Cleaning");
  info(res.events.done || "Done", "Empty the Trash in Finder to free what's in it, too." +
    (res.events.warnings.length ? "\n\n" + res.events.warnings.join("\n") : ""));
}

// ---------------------------------------------------------------------------

// A backup or restore started earlier (or from Terminal) is still running: show it
function attach() {
  var pid = readFile(STATE + "/lock/pid").trim();
  if (!pid || !alive(null, pid)) return false;
  var started = readFile(STATE + "/lock/start").trim();
  if (sh("ps -o lstart= -p " + pid).trim() !== started) return false;
  var what = readFile(STATE + "/lock/what").trim() || "mac-migrate";
  var run = readFile(STATE + "/lock/run").trim();
  if (!run) { info("A " + what + " is running in Terminal", "Wait for it to finish there before you start something else here."); return true; }
  RUN = run;
  var res = monitor(null, "The " + what + " is running", pid, function () {
    return confirm("Stop the " + what + "?", "It continues where it stopped when you start it again.", "Stop", "Keep going");
  });
  if (res.code === 0) info("The " + what + " is done", res.events.done || "");
  else explainFailure(res, "The " + what);
  return true;
}

function homeChoice() {
  return choose("Mac Migrate", "Move your settings, keys and projects to a new Mac, without Migration Assistant.", [
      { label: "Back up this Mac", detail: "Pack everything into encrypted archives on a cloud drive or disk" },
      { label: "Restore on this Mac", detail: "Unpack a backup made on your old Mac" },
      { label: "Free up space", detail: "Clear caches that tools rebuild by themselves" },
      { label: "Open the logs", detail: tilde(STATE + "/logs") },
  ], 0, ["Continue", "Quit"]);
}

function home() {
  for (;;) {
    var c = homeChoice();
    if (c.button !== 0 || c.index < 0) return;
    [backup, restore, cleanup, openLogs][c.index]();
  }
}

function run(argv) {
  argv = argv || [];
  if (argv[0] === "--self-test") return selfTest(argv[1]);
  if (argv[0] === "--screenshots") return screenshots(argv[1], argv[2], argv[3] === "dark");
  ENGINE = ObjC.unwrap($.NSBundle.mainBundle.resourcePath) + "/engine";
  $.NSApplication.sharedApplication;
  if (!exists(ENGINE + "/backup.sh")) {
    info("Mac Migrate is incomplete", "The scripts are missing from the app. Build it again with make-app.sh.", ["Quit"], true);
    return;
  }
  if (attach()) return;
  home();
}

// ---------------------------------------------------------------------------

function selfTest(engine) {
  var out = [], fails = 0;
  function check(name, ok) { out.push((ok ? "  ok    " : "  FAIL  ") + name); if (!ok) fails++; }
  check("size in KB", size(512) === "512 KB");
  check("size in MB", size(5 * 1024) === "5 MB");
  check("size in GB", size(1.5 * 1048576) === "1.5 GB");
  check("size of big folders", size(250 * 1048576) === "250 GB");
  check("time left in minutes", timeLeft(38 * 60) === "about 38 min left");
  check("time left in hours", timeLeft(65 * 60) === "about 1 h 05 min left");
  check("unknown time left", timeLeft(-1) === "");
  var s = parseStatus("pack\tprojects-03\t43008\t117440\t51200\t2280\t\n");
  check("status parsed", s.phase === "pack" && s.item === "projects-03" && s.total === 117440 && s.eta === 2280);
  var d = describe(s);
  check("packing title", d.title === "Packing projects-03…");
  check("packing detail", d.detail === "42 MB of 115 MB · 50 MB/s · about 38 min left");
  check("packing fraction", Math.abs(d.fraction - 43008 / 117440) < 1e-9);
  d = describe(parseStatus("upload\t\t0\t3145728\t0\t-1\tWaiting for Google Drive to upload 2 file(s), 3.0 GB left"));
  check("upload uses the engine's message", d.title.indexOf("Waiting for Google Drive") === 0 && d.fraction === -1);
  check("no status yet", describe(null).title === "Starting…");
  var ev = parseEvents("log\t/x.log\nwarn\tskipped\nfile\t/a.enc\nfolder\t/b\nmode\tcloud\nprovider\tGoogle Drive\nrestore\t/bin/bash ~/b/restore.sh\ndone\t3 file(s)\nresult\t15\tstalled\n");
  check("events parsed", ev.result.code === 15 && ev.result.reason === "stalled" && ev.files[0] === "/a.enc" && ev.provider === "Google Drive" && ev.restore.indexOf("restore.sh") > 0);
  var p = parsePlaces("gdrive:a@b.c\tcloud\tGoogle Drive (a@b.c)\t/U/x/My Drive\t1024\tcloud\t\t\ndisk:T7\tdisk\tDisk “T7”\t/Volumes/T7\t2048\tmsdos\t3900\tFAT32 disk\n");
  check("places parsed", p.length === 2 && p[0].path === "/U/x/My Drive" && p[1].partMb === "3900" && p[1].note === "FAT32 disk");
  check("cloud place explained", placeDetail(p[0]).indexOf("freed here once uploaded") > 0);
  var rep = parseReport("folder\t/x\ncomplete\tno\narchive\tsettings\tdone\t12\narchive\tprojects-01\tpending\t2048\naside\t.zshrc\nmerge\tDownloads\n");
  check("report parsed", rep.complete === "no" && rep.archives.length === 2 && rep.archives[1].kb === 2048 && rep.aside[0] === ".zshrc" && rep.merge[0] === "Downloads");
  var src = parseSources("settings\tsettings\t100\t1\tAlways\nprojects\tproj\t2048\t1\t\nfolder\tDocuments\t0\t0\tSynced by iCloud\n");
  check("sources parsed", src.length === 3 && src[1].on && !src[2].on && src[2].note === "Synced by iCloud");
  check("cleanup parsed", parseCleanup("npm\tnpm cache\t1024\tsafe\t1\t\n")[0].on === true);
  check("shell quoting", q("it's") === "'it'\\''s'");

  if (engine) {
    ENGINE = engine;
    RUN = ObjC.unwrap($.NSTemporaryDirectory()) + "mac-migrate-selftest-" + Date.now();
    var r = run_("fake-engine.sh", [], "test", { password: "secret", env: { FAKE_SCENARIO: "ok" } });
    check("engine run: result read from events", r.code === 0 && r.events.done === "3 files");
    check("engine run: password reached the engine on stdin", readFile(RUN + "/engine.out").indexOf("password ok") >= 0);
    r = run_("fake-engine.sh", [], "test", { password: "wrong", env: { FAKE_SCENARIO: "ok" } });
    check("engine run: exit code 10 for a wrong password", r.code === 10);
    r = run_("fake-engine.sh", ["--list"], "test", { capture: true, env: { FAKE_SCENARIO: "list" } });
    check("engine run: output captured", parsePlaces(r.out)[0].label === "Google Drive (a@b)");
    var t = start("fake-engine.sh", [], { env: { FAKE_SCENARIO: "slow" } });
    delay(1);
    var pid = t.processIdentifier;
    stop(pid);
    r = monitor(t, "test", pid);
    var left = sh("pgrep -g " + pid + " || true").trim();
    check("Stop ends the engine and its children (code " + r.code + (left ? ", left: " + left : "") + ")", r.code === 143 && left === "");
    remove(RUN);
  }
  var text = out.join("\n") + "\n\n" + (fails ? fails + " check(s) failed." : "All checks passed.");
  if (fails) throw new Error(text);
  return text;
}

// Pictures of the main windows with sample data, for the README and the website:
//   osascript -l JavaScript app/main.js --screenshots <folder> build/icon.png [dark]
function screenshots(dir, icon, dark) {
  $.NSApplication.sharedApplication;
  if (icon && exists(icon)) SHOT_ICON = $.NSImage.alloc.initWithContentsOfFile(icon);
  mkdirs(dir);
  SHOT_DARK = dark;
  var sfx = dark ? "-dark" : "";
  function shot(name) { SHOT = dir + "/" + name + sfx + ".png"; }
  shot("home"); homeChoice();
  var places = parsePlaces("gdrive:you@company.com\tcloud\tGoogle Drive (you@company.com)\t/x\t" + 412 * 1048576 + "\tcloud\t\t\n" +
    "icloud\tcloud\tiCloud Drive\t/y\t" + 412 * 1048576 + "\tcloud\t\tUses your Apple account. Check your company's policy before you put work files there.\n" +
    "disk:T7\tdisk\tDisk “T7”\t/Volumes/T7\t" + 890 * 1048576 + "\texfat\t\t\n");
  var options = places.map(function (p) { return { label: p.label, detail: placeDetail(p) }; });
  options.push({ label: "Another folder…", detail: "A network share, or a folder you choose" });
  shot("destination"); choose("Where should the backup go?", "Everything is encrypted with a password you choose before it leaves this Mac.", options, 0);
  shot("include");
  checklist("What should go into the backup?", "node_modules, virtual environments and similar folders are left out: you reinstall them per project.", [
    { heading: "Always included", items: [{ label: "Settings, keys and tools", kb: 1.2 * 1048576, on: true, locked: true, detail: "Keys, shell, git and editor settings, Claude Code." }] },
    { heading: "Projects", items: [{ label: "~/proj", kb: 23.4 * 1048576, on: true, detail: "Every folder in it, with uncommitted work" }, { label: "~/Developer", kb: 3.1 * 1048576, on: true }] },
    { heading: "Folders in your home folder", items: [{ label: "~/Desktop", kb: 812 * 1024, on: true }, { label: "~/Documents", on: false, locked: true, detail: "Synced by iCloud or another cloud drive, so it is left out" },
      { label: "~/Downloads", kb: 14.8 * 1048576, on: false }, { label: "~/Pictures", kb: 41.3 * 1048576, on: false }] },
  ], ["Continue", "Free up space…", "Cancel"], function (items) {
    return "Selected: " + size(items.reduce(function (t, it) { return t + it.kb; }, 0)) + " before compression · 412 GB free here";
  });
  shot("password"); password("Choose a password for the backup", "Save it in your password manager now. Without it nobody can open the archives, including you.", true);
  shot("done");
  backupDone({ done: "14 file(s), 21.7 GB in ~/Library/CloudStorage/GoogleDrive-you@company.com/My Drive/mac-migration-old-mac-20261017",
    folder: HOME + "/Library/CloudStorage/GoogleDrive-you@company.com/My Drive/mac-migration-old-mac-20261017",
    mode: "cloud", provider: "Google Drive", warnings: ["2 git repos are outside the backup, see ~/.mac-migration/inventory.md"],
    restore: "/bin/bash ~/Library/CloudStorage/GoogleDrive-you@company.com/My\\ Drive/mac-migration-old-mac-20261017/restore.sh" });
  shot("cleanup");
  checklist("Free up space", "Only caches and build output that tools recreate are listed. The first group is safe to clear any time.", [
    { heading: "Rebuilt automatically", items: [{ label: "Homebrew downloads", kb: 1.8 * 1048576, on: true }, { label: "npm cache", kb: 1.4 * 1048576, on: true },
      { label: "uv cache", kb: 1.4 * 1048576, on: true }, { label: "JetBrains IDE caches", kb: 676 * 1024, on: false, detail: "Quit your JetBrains IDEs first" }] },
    { heading: "Downloaded again when needed: big, and slow to get back", items: [{ label: "Hugging Face models and datasets", kb: 11.6 * 1048576, on: false }] },
    { heading: "In your projects: the backup leaves these out anyway", items: [{ label: "node_modules in 3 project(s)", kb: 1.0 * 1048576, on: false, detail: "Reinstall with npm install when you open a project" }] },
  ], ["Clean", "Cancel"], function (sel) { return "Selected: " + size(sel.reduce(function (t, i) { return t + i.kb; }, 0)); });
  shot("restore");
  confirm("Restore this backup?", "Restores 14 archive(s), 23.0 GB, into your home folder. 380 GB is free.\n\n" +
    "These exist already and are moved to ~/.mac-migration-restore first: .zshrc, .gitconfig, .ssh.\n\nThese folders are merged, files you have here stay: Desktop, Downloads.", "Restore");
  return "Saved pictures in " + dir;
}
