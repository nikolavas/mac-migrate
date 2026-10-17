// Upload and download state of files in cloud folders (iCloud Drive, Google Drive, OneDrive, Dropbox).
// Usage: osascript -l JavaScript cloud.js status|evict|download <path>...
//   status    path<TAB>cloud(0|1)<TAB>uploaded(0|1)<TAB>uploading(0|1)<TAB>local(1|0|-)<TAB>error or -
//   evict     path<TAB>ok or error: removes the local copy of an uploaded file, the cloud copy stays
//   download  path<TAB>ok or error: starts downloading a cloud-only file
ObjC.import("Foundation");

function value(url, key) {
  var v = Ref();
  if (!url.getResourceValueForKeyError(v, key, null)) return undefined;
  return v[0];
}

function flag(v) {
  return v === undefined || v.isNil() ? "0" : (ObjC.unwrap(v) ? "1" : "0");
}

function status(path) {
  var url = $.NSURL.fileURLWithPath(path);
  var cloud = flag(value(url, $.NSURLIsUbiquitousItemKey));
  if (cloud === "0") return [path, "0", "0", "0", "-", "-"].join("\t");
  var dl = value(url, $.NSURLUbiquitousItemDownloadingStatusKey);
  dl = dl === undefined || dl.isNil() ? "-" : ObjC.unwrap(dl);
  var local = dl === "-" ? "-" : (dl === ObjC.unwrap($.NSURLUbiquitousItemDownloadingStatusNotDownloaded) ? "0" : "1");
  var err = value(url, $.NSURLUbiquitousItemUploadingErrorKey);
  err = err === undefined || err.isNil() ? "-" : ObjC.unwrap(err.localizedDescription).replace(/\s+/g, " ");
  return [path, cloud, flag(value(url, $.NSURLUbiquitousItemIsUploadedKey)),
    flag(value(url, $.NSURLUbiquitousItemIsUploadingKey)), local, err].join("\t");
}

// Error out-parameters need $(), a Ref() crashes osascript when the call fails
function act(path, method) {
  var err = $();
  var ok = $.NSFileManager.defaultManager[method]($.NSURL.fileURLWithPath(path), err);
  return path + "\t" + (ok ? "ok" : "error: " + (err.isNil() ? "unknown" : ObjC.unwrap(err.localizedDescription)));
}

function run(argv) {
  var cmd = argv.shift();
  var fn = {
    status: status,
    evict: function (p) { return act(p, "evictUbiquitousItemAtURLError"); },
    download: function (p) { return act(p, "startDownloadingUbiquitousItemAtURLError"); },
  }[cmd];
  if (!fn) return "usage: cloud.js status|evict|download <path>...";
  return argv.map(fn).join("\n");
}
