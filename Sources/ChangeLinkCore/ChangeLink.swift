import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(SQLite3)
import SQLite3
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

public struct FileRecord: Codable, Equatable, Sendable { public let path,fileID:String; public let size:Int64; public let modificationDate:Date; public let isDirectory:Bool; public let contentHash:String?; public init(path:String,fileID:String,size:Int64,modificationDate:Date,isDirectory:Bool,contentHash:String?=nil){self.path=path;self.fileID=fileID;self.size=size;self.modificationDate=modificationDate;self.isDirectory=isDirectory;self.contentHash=contentHash} }
public struct Snapshot: Codable, Equatable, Sendable { public let root:URL,takenAt:Date,files:[String:FileRecord]; public init(root:URL,takenAt:Date=Date(),files:[String:FileRecord]){self.root=root;self.takenAt=takenAt;self.files=files} }
public enum ChangeKind:String,Codable,Sendable,CaseIterable { case create,delete,modify,rename,move }
public enum NodeKind:String,Codable,Sendable { case file,directory }
public struct ChangeEvent:Codable,Equatable,Sendable { public let kind:ChangeKind; public let oldPath:String?; public let path,fileID:String; public let nodeKind:NodeKind; public let previousSize:Int64?; public let currentSize:Int64?; public let contentChanged:Bool; public let observedAt:Date; public init(kind:ChangeKind,oldPath:String?=nil,path:String,fileID:String,nodeKind:NodeKind = .file,previousSize:Int64?=nil,currentSize:Int64?=nil,contentChanged:Bool=false,observedAt:Date=Date()){self.kind=kind;self.oldPath=oldPath;self.path=path;self.fileID=fileID;self.nodeKind=nodeKind;self.previousSize=previousSize;self.currentSize=currentSize;self.contentChanged=contentChanged;self.observedAt=observedAt} }

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
   result[relativePath]=FileRecord(path:relativePath,fileID:id,size:Int64(v.fileSize ?? 0),modificationDate:v.contentModificationDate ?? .distantPast,isDirectory:v.isDirectory ?? false,contentHash:hashContents && v.isDirectory != true ? (try? sha256(u)) : nil)
  }
  return Snapshot(root:root,files:result)
 }
 private static func sha256(_ url: URL) throws -> String {
  let d = try Data(contentsOf: url)
  #if canImport(CryptoKit)
  return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
  #else
  return d.map { String(format: "%02x", $0) }.joined()
  #endif
 }
}
public enum SnapshotComparator { public static func compare(_ old:Snapshot,_ new:Snapshot)->[ChangeEvent] { var out:[ChangeEvent]=[]; let oldID=Dictionary(grouping:old.files.values,by:\.fileID), newID=Set(new.files.values.map(\.fileID)); for (p,r) in new.files { let nodeKind:NodeKind = r.isDirectory ? .directory : .file; if old.files[p] == nil { if let prior=oldID[r.fileID]?.first { let sameDir=URL(fileURLWithPath:prior.path).deletingLastPathComponent().path == URL(fileURLWithPath:p).deletingLastPathComponent().path; out.append(ChangeEvent(kind:sameDir ? .rename:.move,oldPath:prior.path,path:p,fileID:r.fileID,nodeKind:nodeKind,previousSize:prior.size,currentSize:r.size,contentChanged:prior.contentHash != r.contentHash)) } else {out.append(ChangeEvent(kind:.create,path:p,fileID:r.fileID,nodeKind:nodeKind,currentSize:r.size,contentChanged:r.contentHash != nil))} } else if old.files[p] != r { let prior=old.files[p]!; out.append(ChangeEvent(kind:.modify,path:p,fileID:r.fileID,nodeKind:nodeKind,previousSize:prior.size,currentSize:r.size,contentChanged:prior.contentHash != r.contentHash)) } }; for (p,r) in old.files where new.files[p] == nil && !newID.contains(r.fileID) {out.append(ChangeEvent(kind:.delete,path:p,fileID:r.fileID,nodeKind:r.isDirectory ? .directory : .file,previousSize:r.size))}; return out.sorted{$0.path<$1.path} } }

public enum Attribution:Codable,Equatable,Sendable { case unknown(reason:String); case process(pid:Int32,name:String,evidence:String) }
public struct AttributedChange:Codable,Equatable,Sendable { public let change:ChangeEvent; public let attribution:Attribution; public init(change:ChangeEvent,attribution:Attribution = .unknown(reason:"No reliable process evidence available")){self.change=change;self.attribution=attribution} }
public protocol AlertProvider { func send(_ message:String) async throws }
public actor MockWhatsAppProvider:AlertProvider { public private(set)var messages:[String]=[]; public init(){}; public func send(_ message:String) async throws{messages.append(message)} }
public struct AlertAggregator { public init(){}; public func message(for changes:[AttributedChange])->String { guard !changes.isEmpty else{return "No file changes"}; return "ChangeLink detected \(changes.count) change(s)\n"+changes.map{"\($0.change.kind.rawValue.uppercased()): \($0.change.path) [\($0.attribution.label)]"}.joined(separator:"\n") } }
private extension Attribution { var label:String { switch self {case .unknown(let r):return "UNKNOWN (\(r))"; case .process(_,let n,_):return n} } }

public final class ChangeStore { private var db:OpaquePointer?; public init(url:URL)throws { guard sqlite3_open(url.path,&db)==SQLITE_OK else{throw NSError(domain:"SQLite",code:1)}; try exec("CREATE TABLE IF NOT EXISTS snapshots(id INTEGER PRIMARY KEY,root TEXT,taken REAL,json BLOB); CREATE TABLE IF NOT EXISTS nodes(snapshot_id INTEGER,path TEXT,file_id TEXT,size INTEGER,modified REAL,hash TEXT); CREATE TABLE IF NOT EXISTS changes(id INTEGER PRIMARY KEY,kind TEXT,old_path TEXT,path TEXT,file_id TEXT,observed REAL,attribution TEXT); CREATE TABLE IF NOT EXISTS alerts(id INTEGER PRIMARY KEY,created REAL,message TEXT); CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT);") }; deinit{sqlite3_close(db)}; private func exec(_ sql:String)throws{var e:UnsafeMutablePointer<CChar>?; guard sqlite3_exec(db,sql,nil,nil,&e)==SQLITE_OK else{let m=e.map{String(cString:$0)} ?? "SQLite error";sqlite3_free(e);throw NSError(domain:"SQLite",code:2,userInfo:[NSLocalizedDescriptionKey:m])}}; public func save(snapshot:Snapshot)throws{let data=try JSONEncoder().encode(snapshot); let q="INSERT INTO snapshots(root,taken,json) VALUES(?,?,?)"; var s:OpaquePointer?; guard sqlite3_prepare_v2(db,q,-1,&s,nil)==SQLITE_OK else{throw NSError(domain:"SQLite",code:3)}; defer{sqlite3_finalize(s)}; sqlite3_bind_text(s,1,snapshot.root.path,-1,SQLITE_TRANSIENT);sqlite3_bind_double(s,2,snapshot.takenAt.timeIntervalSince1970);data.withUnsafeBytes{sqlite3_bind_blob(s,3,$0.baseAddress,Int32(data.count),SQLITE_TRANSIENT)};guard sqlite3_step(s)==SQLITE_DONE else{throw NSError(domain:"SQLite",code:4)}}; public func insert(_ c:AttributedChange)throws{let q="INSERT INTO changes(kind,old_path,path,file_id,observed,attribution) VALUES(?,?,?,?,?,?)";var s:OpaquePointer?;guard sqlite3_prepare_v2(db,q,-1,&s,nil)==SQLITE_OK else{throw NSError(domain:"SQLite",code:5)};defer{sqlite3_finalize(s)};sqlite3_bind_text(s,1,c.change.kind.rawValue,-1,SQLITE_TRANSIENT);if let p=c.change.oldPath{sqlite3_bind_text(s,2,p,-1,SQLITE_TRANSIENT)}else{sqlite3_bind_null(s,2)};sqlite3_bind_text(s,3,c.change.path,-1,SQLITE_TRANSIENT);sqlite3_bind_text(s,4,c.change.fileID,-1,SQLITE_TRANSIENT);sqlite3_bind_double(s,5,c.change.observedAt.timeIntervalSince1970);sqlite3_bind_text(s,6,"UNKNOWN",-1,SQLITE_TRANSIENT);guard sqlite3_step(s)==SQLITE_DONE else{throw NSError(domain:"SQLite",code:6)}}; public func recordAlert(_ message:String)throws{try exec("INSERT INTO alerts(created,message) VALUES(\(Date().timeIntervalSince1970),'\(message.replacingOccurrences(of:"'",with:"''"))')")} }

public protocol ChangeWatcher { func start(root:URL,interval:TimeInterval,onChanges:@escaping([ChangeEvent])->Void)throws; func stop() }
public final class PollingWatcher:ChangeWatcher { private var timer:DispatchSourceTimer?; private var previous:Snapshot?; public init(){}; public func start(root:URL,interval:TimeInterval=2,onChanges:@escaping([ChangeEvent])->Void)throws{previous=Snapshotter.take(root:root,hashContents:true);let t=DispatchSource.makeTimerSource();t.schedule(deadline:.now()+interval,repeating:interval);t.setEventHandler{[weak self] in guard let self else{return};let n=Snapshotter.take(root:root,hashContents:true);let c=SnapshotComparator.compare(self.previous!,n);self.previous=n;onChanges(c)};t.resume();timer=t}; public func stop(){timer?.cancel();timer=nil} }
#if canImport(CoreServices)
import CoreServices
private final class FSEventCallbackBox: NSObject { let callback: () -> Void; init(_ callback: @escaping () -> Void) { self.callback = callback } }
public final class FSEventsWatcher: ChangeWatcher {
 private var stream: FSEventStreamRef?
 private var previous: Snapshot?
 public init() {}
 public func start(root: URL, interval: TimeInterval = 2, onChanges: @escaping ([ChangeEvent]) -> Void) throws {
  previous = Snapshotter.take(root: root)
  let box = FSEventCallbackBox { [weak self] in guard let self, let old = self.previous else { return }; let next = Snapshotter.take(root: root); let changes = SnapshotComparator.compare(old, next); self.previous = next; if !changes.isEmpty { onChanges(changes) } }
  let callback: FSEventStreamCallback = { _, info, _, _, _, _ in if let info { Unmanaged<FSEventCallbackBox>.fromOpaque(info).takeUnretainedValue().callback() } }
  var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil, release: { info in if let info { Unmanaged<FSEventCallbackBox>.fromOpaque(info).release() } }, copyDescription: nil)
  stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), interval, UInt32(kFSEventStreamCreateFlagFileEvents))
  guard let stream else { throw NSError(domain: "FSEvents", code: 1) }
  FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue); FSEventStreamStart(stream)
 }
 public func stop() { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil } }
}
#else
public typealias FSEventsWatcher=PollingWatcher
#endif

public final class MonitorScheduler { private let watcher:ChangeWatcher; public init(watcher:ChangeWatcher=PollingWatcher()){self.watcher=watcher}; public func start(root:URL,interval:TimeInterval=2,onChanges:@escaping([ChangeEvent])->Void)throws{try watcher.start(root:root,interval:interval,onChanges:onChanges)}; public func stop(){watcher.stop()} }
