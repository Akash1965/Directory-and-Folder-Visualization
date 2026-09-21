#if canImport(XCTest)
import XCTest
@testable import ChangeLinkCore
final class ChangeLinkTests: XCTestCase {
 let root=URL(fileURLWithPath:"/")
 func r(_ p:String,_ id:String,_ size:Int64=1)->FileRecord{FileRecord(path:p,fileID:id,size:size,modificationDate:Date(timeIntervalSince1970:1),isDirectory:false)}
 func testCreate(){XCTAssertEqual(SnapshotComparator.compare(Snapshot(root:root,files:[:]),Snapshot(root:root,files:["a":r("a","1")])).first?.kind,.create)}
 func testDelete(){XCTAssertEqual(SnapshotComparator.compare(Snapshot(root:root,files:["a":r("a","1")]),Snapshot(root:root,files:[])).first?.kind,.delete)}
 func testModify(){let a=Snapshot(root:root,files:["a":r("a","1")]);let b=Snapshot(root:root,files:["a":r("a","1",2)]);XCTAssertEqual(SnapshotComparator.compare(a,b).first?.kind,.modify)}
 func testRenameAndMove(){let a=Snapshot(root:root,files:["d/a":r("d/a","id")]);let b=Snapshot(root:root,files:["d/b":r("d/b","id")]);XCTAssertEqual(SnapshotComparator.compare(a,b).first?.kind,.rename);let c=Snapshot(root:root,files:["e/b":r("e/b","id")]);XCTAssertEqual(SnapshotComparator.compare(b,c).first?.kind,.move)}
 func testHiddenAndHash()throws{let d=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:d)};try Data("x".utf8).write(to:d.appendingPathComponent(".hidden"));let s=Snapshotter.take(root:d,hashContents:true);XCTAssertNotNil(s.files[".hidden"]?.contentHash)}
 func testSQLiteAndAlert()async throws{let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);let store=try ChangeStore(url:u);let c=AttributedChange(change:ChangeEvent(kind:.create,path:"a",fileID:"1"));try store.insert(c);let p=MockWhatsAppProvider();try await p.send(AlertAggregator().message(for:[c]));XCTAssertEqual(await p.messages.count,1);try? FileManager.default.removeItem(at:u)}
}
#else
import Foundation
@testable import ChangeLinkCore
func _changeLinkChecks(){let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);_ = try? ChangeStore(url:u);try? FileManager.default.removeItem(at:u)}
#endif
