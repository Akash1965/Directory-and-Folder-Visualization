import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(SQLite3)
import SQLite3
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

/// `entropy` (bits/byte, 0–8), `distinctByteCount` (how many of the 256 byte values appeared in the
/// sample) and `prefixHash` (a hash of a small fixed leading window) are measured only when
/// `hashContents` is on, from the same read used for `contentHash`; together they let a later
/// modification be classified (appended / truncated / likely encrypted) without re-reading the file.
/// All three are `nil` for directories and whenever content hashing is off.
public struct FileRecord: Codable, Equatable, Sendable { public let path,fileID:String; public let size:Int64; public let modificationDate:Date; public let isDirectory:Bool; public let contentHash:String?; public let entropy:Double?; public let prefixHash:String?; public let distinctByteCount:Int?; public init(path:String,fileID:String,size:Int64,modificationDate:Date,isDirectory:Bool,contentHash:String?=nil,entropy:Double?=nil,prefixHash:String?=nil,distinctByteCount:Int?=nil){self.path=path;self.fileID=fileID;self.size=size;self.modificationDate=modificationDate;self.isDirectory=isDirectory;self.contentHash=contentHash;self.entropy=entropy;self.prefixHash=prefixHash;self.distinctByteCount=distinctByteCount} }
public struct Snapshot: Codable, Equatable, Sendable { public let root:URL,takenAt:Date,files:[String:FileRecord]; public init(root:URL,takenAt:Date=Date(),files:[String:FileRecord]){self.root=root;self.takenAt=takenAt;self.files=files} }
public enum ChangeKind:String,Codable,Sendable,CaseIterable { case create,delete,modify,rename,move }
public enum NodeKind:String,Codable,Sendable { case file,directory }
/// `contentChangeKind`, `previousEntropy` and `currentEntropy` are set only for a `.modify` event whose
/// content actually changed, and only when both snapshots carried entropy/prefix data for that path.
public struct ChangeEvent:Codable,Equatable,Sendable { public let kind:ChangeKind; public let oldPath:String?; public let path,fileID:String; public let nodeKind:NodeKind; public let previousSize:Int64?; public let currentSize:Int64?; public let contentChanged:Bool; public let observedAt:Date; public let contentChangeKind:ContentChangeKind?; public let previousEntropy:Double?; public let currentEntropy:Double?; public init(kind:ChangeKind,oldPath:String?=nil,path:String,fileID:String,nodeKind:NodeKind = .file,previousSize:Int64?=nil,currentSize:Int64?=nil,contentChanged:Bool=false,observedAt:Date=Date(),contentChangeKind:ContentChangeKind?=nil,previousEntropy:Double?=nil,currentEntropy:Double?=nil){self.kind=kind;self.oldPath=oldPath;self.path=path;self.fileID=fileID;self.nodeKind=nodeKind;self.previousSize=previousSize;self.currentSize=currentSize;self.contentChanged=contentChanged;self.observedAt=observedAt;self.contentChangeKind=contentChangeKind;self.previousEntropy=previousEntropy;self.currentEntropy=currentEntropy} }

public enum Snapshotter {
 public static func take(root:URL,hashContents:Bool=false)->Snapshot {
  var result:[String:FileRecord]=[:]
  let keys:Set<URLResourceKey>=[.isDirectoryKey,.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey]
   let rootURL = root.standardizedFileURL
  let enumerator = FileManager.default.enumerator(atPath: rootURL.path)
  while let relativePath = enumerator?.nextObject() as? String {
   let u = rootURL.appendingPathComponent(relativePath)
   guard let v=try? u.resourceValues(forKeys:keys) else { continue }
   let id=(v.fileResourceIdentifier as? NSObject)?.description ?? "path:"+u.path
   let d = (hashContents && v.isDirectory != true) ? (try? digest(u)) : nil
   result[relativePath]=FileRecord(path:relativePath,fileID:id,size:Int64(v.fileSize ?? 0),modificationDate:v.contentModificationDate ?? .distantPast,isDirectory:v.isDirectory ?? false,contentHash:d?.hash,entropy:d?.entropy,prefixHash:d?.prefixHash,distinctByteCount:d?.distinctByteCount)
  }
  return Snapshot(root:root,files:result)
 }
/// - Parameter previous: when given, a file whose ID, size and modification date are unchanged reuses its earlier hash instead of being re-read (fast live refreshes).
 public static func takeValidated(root:URL,hashContents:Bool=false,reusingHashesFrom previous:Snapshot?=nil)throws->Snapshot {
  let rootURL = root.standardizedFileURL
  let rootValues = try rootURL.resourceValues(forKeys:[.isDirectoryKey])
  guard rootValues.isDirectory == true else {
   throw NSError(domain:"ChangeLink.Snapshot",code:1,userInfo:[NSLocalizedDescriptionKey:"The selected root is unavailable or is not a directory: \(root.path)"])
  }
  let keys:Set<URLResourceKey>=[.isDirectoryKey,.isRegularFileKey,.fileSizeKey,.contentModificationDateKey,.fileResourceIdentifierKey]
  // The enumerator may report either the path we passed in or its symlink-resolved form
  // (for example /var/... versus /private/var/... on macOS), so accept both prefixes.
  let rawRootComponents=rootURL.pathComponents
  let resolvedRootComponents=rootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
  var traversalFailure:String?
  guard let enumerator=FileManager.default.enumerator(at:rootURL,includingPropertiesForKeys:Array(keys),options:[],errorHandler:{ url,error in
   traversalFailure="Could not enumerate \(url.path): \(error.localizedDescription)"
   return false
  }) else {
   throw NSError(domain:"ChangeLink.Snapshot",code:2,userInfo:[NSLocalizedDescriptionKey:"Could not enumerate the selected root: \(root.path)"])
  }
  var result:[String:FileRecord]=[:]
  while let url=enumerator.nextObject() as? URL {
   // An item can disappear between listing and inspection; that is a normal race, not a scan failure.
   guard let values=try? url.resourceValues(forKeys:keys) else { continue }
   let pathComponents=url.standardizedFileURL.pathComponents
   let relativeComponents:ArraySlice<String>
   if pathComponents.starts(with:rawRootComponents) {
    relativeComponents=pathComponents.dropFirst(rawRootComponents.count)
   } else if pathComponents.starts(with:resolvedRootComponents) {
    relativeComponents=pathComponents.dropFirst(resolvedRootComponents.count)
   } else {
    throw NSError(domain:"ChangeLink.Snapshot",code:4,userInfo:[NSLocalizedDescriptionKey:"An enumerated path was outside the selected root: \(url.path)"])
   }
   let relativePath=relativeComponents.joined(separator:"/")
   if relativePath.isEmpty { continue }
   let id=(values.fileResourceIdentifier as? NSObject)?.description ?? "path:"+url.path
   let isDirectory=values.isDirectory ?? false
   // Only regular files are hashed; an unreadable file or a broken symlink must not abort the whole snapshot.
   let size=Int64(values.fileSize ?? 0)
   let modified=values.contentModificationDate ?? .distantPast
   var hash:String?; var entropy:Double?; var prefixHash:String?; var distinctByteCount:Int?
   if hashContents && values.isRegularFile == true {
    if let old=previous?.files[relativePath],old.fileID == id,old.size == size,old.modificationDate == modified,let reused=old.contentHash {
     hash=reused; entropy=old.entropy; prefixHash=old.prefixHash; distinctByteCount=old.distinctByteCount
    } else if let d=try? digest(url) {
     hash=d.hash; entropy=d.entropy; prefixHash=d.prefixHash; distinctByteCount=d.distinctByteCount
    }
   }
   result[relativePath]=FileRecord(path:relativePath,fileID:id,size:size,modificationDate:modified,isDirectory:isDirectory,contentHash:hash,entropy:entropy,prefixHash:prefixHash,distinctByteCount:distinctByteCount)
  }
  if let traversalFailure {
   throw NSError(domain:"ChangeLink.Snapshot",code:3,userInfo:[NSLocalizedDescriptionKey:traversalFailure])
  }
  return Snapshot(root:root,files:result)
 }
 /// One pass over the file that produces everything a later modification can be classified from:
 /// the content hash, a hash of just the leading bytes (to recognise an append or a truncation
 /// without re-reading the whole file later), and the Shannon entropy of that same leading sample
 /// (to recognise content that now looks encrypted). Streamed in chunks so large files are never
 /// loaded into memory at once.
 private struct ContentDigest { let hash:String; let prefixHash:String; let entropy:Double; let distinctByteCount:Int }
 /// Size of the fixed leading window hashed for `prefixHash`. This must stay the SAME size
 /// regardless of the file's total length, so that appending bytes past this window (or
 /// shortening the file down to it) leaves the hash unchanged and only a genuine edit to the
 /// file's opening bytes changes it. Kept small (64 bytes, roughly a CSV header line) so that
 /// append/truncate detection also works on the small files typical of quick edits and tests;
 /// a file shorter than this window is its own whole prefix, so appending to it still only
 /// adds bytes past the window once the file has grown beyond 64 bytes.
 private static let prefixWindowSize = 64
 private static func digest(_ url: URL) throws -> ContentDigest {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var counts = [Int](repeating: 0, count: 256)
  var sampled = 0
  let sampleLimit = 1 << 20   // first 1 MiB is enough to tell text/CSV from encrypted/compressed data
  var prefix = Data()
  var sawFirstChunk = false
  #if canImport(CryptoKit)
  var hasher = SHA256()
  while true {
   let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
   if chunk.isEmpty { break }
   hasher.update(data: chunk)
   if !sawFirstChunk { prefix = chunk.prefix(prefixWindowSize); sawFirstChunk = true }
   if sampled < sampleLimit { for byte in chunk.prefix(sampleLimit - sampled) { counts[Int(byte)] += 1 }; sampled += chunk.count }
  }
  let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  let prefixHash = Insecure.MD5.hash(data: prefix).map { String(format: "%02x", $0) }.joined()
  #else
  var h: UInt64 = 0xcbf29ce484222325
  while true {
   let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
   if chunk.isEmpty { break }
   for byte in chunk { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
   if !sawFirstChunk { prefix = chunk.prefix(prefixWindowSize); sawFirstChunk = true }
   if sampled < sampleLimit { for byte in chunk.prefix(sampleLimit - sampled) { counts[Int(byte)] += 1 }; sampled += chunk.count }
  }
  let hash = String(format: "%016llx", h)
  var ph: UInt64 = 0xcbf29ce484222325
  for byte in prefix { ph = (ph ^ UInt64(byte)) &* 0x100000001b3 }
  let prefixHash = String(format: "%016llx", ph)
  #endif
  let total = Double(sampled)
  var entropySum = 0.0
  var distinctByteCount = 0
  if total > 0 {
   for count in counts where count > 0 { let p = Double(count) / total; entropySum -= p * log2(p); distinctByteCount += 1 }
  }
  return ContentDigest(hash: hash, prefixHash: prefixHash, entropy: entropySum, distinctByteCount: distinctByteCount)
 }
}
public enum SnapshotComparator {
 public static func compare(_ old:Snapshot,_ new:Snapshot)->[ChangeEvent] {
  var out:[ChangeEvent]=[]
  // Several old paths can share one file ID (hard links), so keep every candidate.
  let oldByID=Dictionary(grouping:old.files.values,by:\.fileID)
  var consumedOldPaths=Set<String>()
  for p in new.files.keys.sorted() {
   guard let r=new.files[p] else { continue }
   let nodeKind:NodeKind = r.isDirectory ? .directory : .file
   if let prior=old.files[p] {
    guard prior != r else { continue }
    // A directory's own mtime changes whenever its children change; that is reported on the children.
    if prior.isDirectory && r.isDirectory && prior.fileID == r.fileID { continue }
    let changed = prior.contentHash != r.contentHash
    let kind = changed ? ModificationClassifier.classify(previousSize:prior.size,currentSize:r.size,previousPrefixHash:prior.prefixHash,currentPrefixHash:r.prefixHash,previousEntropy:prior.entropy,currentEntropy:r.entropy,previousDistinctByteCount:prior.distinctByteCount,currentDistinctByteCount:r.distinctByteCount,contentChanged:true) : nil
    out.append(ChangeEvent(kind:.modify,path:p,fileID:r.fileID,nodeKind:nodeKind,previousSize:prior.size,currentSize:r.size,contentChanged:changed,contentChangeKind:kind,previousEntropy:prior.entropy,currentEntropy:r.entropy))
   } else {
    // Only an old path that has really vanished can be the source of a rename/move.
    // A still-present path with the same ID is a hard link, so this is a new file.
    let source=(oldByID[r.fileID] ?? []).sorted{$0.path<$1.path}.first{ new.files[$0.path] == nil && !consumedOldPaths.contains($0.path) }
    if let prior=source {
     consumedOldPaths.insert(prior.path)
     let sameDir=parentPath(prior.path) == parentPath(p)
     out.append(ChangeEvent(kind:sameDir ? .rename:.move,oldPath:prior.path,path:p,fileID:r.fileID,nodeKind:nodeKind,previousSize:prior.size,currentSize:r.size,contentChanged:prior.contentHash != r.contentHash))
    } else {
     out.append(ChangeEvent(kind:.create,path:p,fileID:r.fileID,nodeKind:nodeKind,currentSize:r.size,contentChanged:r.contentHash != nil))
    }
   }
  }
  for (p,r) in old.files where new.files[p] == nil && !consumedOldPaths.contains(p) {
   out.append(ChangeEvent(kind:.delete,path:p,fileID:r.fileID,nodeKind:r.isDirectory ? .directory : .file,previousSize:r.size))
  }
  return out.sorted{ $0.path != $1.path ? $0.path<$1.path : $0.kind.rawValue<$1.kind.rawValue }
 }
 static func parentPath(_ p:String)->String {
  guard let i=p.lastIndex(of:"/") else { return "" }
  return String(p[..<i])
 }
}

public enum Attribution:Codable,Equatable,Sendable { case unknown(reason:String); case process(pid:Int32,name:String,evidence:String) }
public struct AttributedChange:Codable,Equatable,Sendable { public let change:ChangeEvent; public let attribution:Attribution; public init(change:ChangeEvent,attribution:Attribution = .unknown(reason:"No reliable process evidence available")){self.change=change;self.attribution=attribution} }
public protocol AlertProvider { func send(_ message:String) async throws }
public actor MockWhatsAppProvider:AlertProvider { public private(set)var messages:[String]=[]; public init(){}; public func send(_ message:String) async throws{messages.append(message)} }
public struct AlertAggregator { public init(){}; public func message(for changes:[AttributedChange])->String { guard !changes.isEmpty else{return "No file changes"}; return "ChangeLink detected \(changes.count) change(s)\n"+changes.map{"\($0.change.kind.rawValue.uppercased()): \($0.change.path) [\($0.attribution.label)]"}.joined(separator:"\n") } }
private extension Attribution { var storedValue:String { switch self {case .unknown(let r):return "UNKNOWN: "+r; case .process(let pid,let n,let e):return "PROCESS \(pid) \(n): "+e} }; var label:String { switch self {case .unknown(let r):return "UNKNOWN (\(r))"; case .process(_,let n,_):return n} } }

public final class ChangeStore { private var db:OpaquePointer?; public init(url:URL)throws { guard sqlite3_open(url.path,&db)==SQLITE_OK else{throw NSError(domain:"SQLite",code:1)}; try exec("CREATE TABLE IF NOT EXISTS snapshots(id INTEGER PRIMARY KEY,root TEXT,taken REAL,json BLOB); CREATE TABLE IF NOT EXISTS nodes(snapshot_id INTEGER,path TEXT,file_id TEXT,size INTEGER,modified REAL,hash TEXT); CREATE TABLE IF NOT EXISTS changes(id INTEGER PRIMARY KEY,kind TEXT,old_path TEXT,path TEXT,file_id TEXT,observed REAL,attribution TEXT); CREATE TABLE IF NOT EXISTS alerts(id INTEGER PRIMARY KEY,created REAL,message TEXT); CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT);") }; deinit{sqlite3_close(db)}; private func exec(_ sql:String)throws{var e:UnsafeMutablePointer<CChar>?; guard sqlite3_exec(db,sql,nil,nil,&e)==SQLITE_OK else{let m=e.map{String(cString:$0)} ?? "SQLite error";sqlite3_free(e);throw NSError(domain:"SQLite",code:2,userInfo:[NSLocalizedDescriptionKey:m])}}; public func save(snapshot:Snapshot)throws{let data=try JSONEncoder().encode(snapshot); let q="INSERT INTO snapshots(root,taken,json) VALUES(?,?,?)"; var s:OpaquePointer?; guard sqlite3_prepare_v2(db,q,-1,&s,nil)==SQLITE_OK else{throw NSError(domain:"SQLite",code:3)}; defer{sqlite3_finalize(s)}; sqlite3_bind_text(s,1,snapshot.root.path,-1,SQLITE_TRANSIENT);sqlite3_bind_double(s,2,snapshot.takenAt.timeIntervalSince1970);_=data.withUnsafeBytes{sqlite3_bind_blob(s,3,$0.baseAddress,Int32(data.count),SQLITE_TRANSIENT)};guard sqlite3_step(s)==SQLITE_DONE else{throw NSError(domain:"SQLite",code:4)}}; public func insert(_ c:AttributedChange)throws{let q="INSERT INTO changes(kind,old_path,path,file_id,observed,attribution) VALUES(?,?,?,?,?,?)";var s:OpaquePointer?;guard sqlite3_prepare_v2(db,q,-1,&s,nil)==SQLITE_OK else{throw NSError(domain:"SQLite",code:5)};defer{sqlite3_finalize(s)};sqlite3_bind_text(s,1,c.change.kind.rawValue,-1,SQLITE_TRANSIENT);if let p=c.change.oldPath{sqlite3_bind_text(s,2,p,-1,SQLITE_TRANSIENT)}else{sqlite3_bind_null(s,2)};sqlite3_bind_text(s,3,c.change.path,-1,SQLITE_TRANSIENT);sqlite3_bind_text(s,4,c.change.fileID,-1,SQLITE_TRANSIENT);sqlite3_bind_double(s,5,c.change.observedAt.timeIntervalSince1970);sqlite3_bind_text(s,6,c.attribution.storedValue,-1,SQLITE_TRANSIENT);guard sqlite3_step(s)==SQLITE_DONE else{throw NSError(domain:"SQLite",code:6)}}; public func recordAlert(_ message:String)throws{let q="INSERT INTO alerts(created,message) VALUES(?,?)";var s:OpaquePointer?;guard sqlite3_prepare_v2(db,q,-1,&s,nil)==SQLITE_OK else{throw NSError(domain:"SQLite",code:7)};defer{sqlite3_finalize(s)};sqlite3_bind_double(s,1,Date().timeIntervalSince1970);sqlite3_bind_text(s,2,message,-1,SQLITE_TRANSIENT);guard sqlite3_step(s)==SQLITE_DONE else{throw NSError(domain:"SQLite",code:8)}} }

public protocol ChangeWatcher { func start(root:URL,interval:TimeInterval,onChanges:@escaping([ChangeEvent])->Void)throws; func stop() }
public final class PollingWatcher:ChangeWatcher {
 private var timer:DispatchSourceTimer?
 private var previous:Snapshot?
 private let queue=DispatchQueue(label:"ChangeLink.PollingWatcher")
 public init(){}
 public func start(root:URL,interval:TimeInterval=2,onChanges:@escaping([ChangeEvent])->Void)throws {
  stop()
  previous=try Snapshotter.takeValidated(root:root,hashContents:true)
  let timer=DispatchSource.makeTimerSource(queue:queue)
  timer.schedule(deadline:.now()+interval,repeating:interval)
  timer.setEventHandler{[weak self] in
   guard let self,let old=self.previous else{return}
   do {
    let current=try Snapshotter.takeValidated(root:root,hashContents:true)
    let changes=SnapshotComparator.compare(old,current)
    self.previous=current
    onChanges(changes)
   } catch {
    NSLog("ChangeLink polling scan failed for %@: %@",root.path,error.localizedDescription)
   }
  }
  timer.resume()
  self.timer=timer
 }
 public func stop(){timer?.cancel();timer=nil;previous=nil}
}
#if canImport(CoreServices)
import CoreServices
private final class FSEventCallbackBox: NSObject { let callback: () -> Void; init(_ callback: @escaping () -> Void) { self.callback = callback } }
public final class FSEventsWatcher: ChangeWatcher {
 private var stream: FSEventStreamRef?
 private var previous: Snapshot?
 public init() {}
 public func start(root: URL, interval: TimeInterval = 2, onChanges: @escaping ([ChangeEvent]) -> Void) throws {
  previous = try Snapshotter.takeValidated(root: root)
  let box = FSEventCallbackBox { [weak self] in
   guard let self,let old=self.previous else{return}
   do {
    let next=try Snapshotter.takeValidated(root:root)
    let changes=SnapshotComparator.compare(old,next)
    self.previous=next
    if !changes.isEmpty { onChanges(changes) }
   } catch {
    NSLog("ChangeLink FSEvents scan failed for %@: %@",root.path,error.localizedDescription)
   }
  }
  let callback: FSEventStreamCallback = { _, info, _, _, _, _ in if let info { Unmanaged<FSEventCallbackBox>.fromOpaque(info).takeUnretainedValue().callback() } }
  var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil, release: { info in if let info { Unmanaged<FSEventCallbackBox>.fromOpaque(info).release() } }, copyDescription: nil)
  stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), interval, UInt32(kFSEventStreamCreateFlagFileEvents))
  guard let stream else { throw NSError(domain: "FSEvents", code: 1) }
  FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue); FSEventStreamStart(stream)
 }
 public func stop() { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil } }
}

/// Lightweight "something changed under these paths" signal for live UI updates.
/// Events are coalesced by the OS for `latency` seconds; the caller decides how to rescan.
public final class FSEventsTrigger {
 private var stream: FSEventStreamRef?
 private let queue = DispatchQueue(label: "ChangeLink.FSEventsTrigger")
 public init() {}
 deinit { stop() }
 @discardableResult
 public func start(paths: [String], latency: TimeInterval = 0.5, onEvent: @escaping () -> Void) -> Bool {
  stop()
  guard !paths.isEmpty else { return false }
  let box = FSEventCallbackBox(onEvent)
  let callback: FSEventStreamCallback = { _, info, _, _, _, _ in if let info { Unmanaged<FSEventCallbackBox>.fromOpaque(info).takeUnretainedValue().callback() } }
  var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil, release: { info in if let info { Unmanaged<FSEventCallbackBox>.fromOpaque(info).release() } }, copyDescription: nil)
  guard let created = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else { return false }
  FSEventStreamSetDispatchQueue(created, queue)
  guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); return false }
  stream = created
  return true
 }
 public func stop() { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil } }
}
#else
public typealias FSEventsWatcher=PollingWatcher
public final class FSEventsTrigger { public init() {}; @discardableResult public func start(paths: [String], latency: TimeInterval = 0.5, onEvent: @escaping () -> Void) -> Bool { false }; public func stop() {} }
#endif

public final class MonitorScheduler { private let watcher:ChangeWatcher; public init(watcher:ChangeWatcher=PollingWatcher()){self.watcher=watcher}; public func start(root:URL,interval:TimeInterval=2,onChanges:@escaping([ChangeEvent])->Void)throws{try watcher.start(root:root,interval:interval,onChanges:onChanges)}; public func stop(){watcher.stop()} }
