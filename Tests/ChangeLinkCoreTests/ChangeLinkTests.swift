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
 func testHardLinkIsCreateNotMove(){let a=Snapshot(root:root,files:["a":r("a","id")]);let b=Snapshot(root:root,files:["a":r("a","id"),"b":r("b","id")]);let e=SnapshotComparator.compare(a,b);XCTAssertEqual(e.count,1);XCTAssertEqual(e.first?.kind,.create)}
 func testDirectoryMtimeAloneIsNotAModify(){func d(_ t:TimeInterval)->FileRecord{FileRecord(path:"d",fileID:"1",size:0,modificationDate:Date(timeIntervalSince1970:t),isDirectory:true)};XCTAssertTrue(SnapshotComparator.compare(Snapshot(root:root,files:["d":d(1)]),Snapshot(root:root,files:["d":d(2)])).isEmpty)}
 func testTreeDiffShowsEveryChangeOnBothSides(){
  let old=Snapshot(root:root,files:["d":FileRecord(path:"d",fileID:"D",size:0,modificationDate:Date(timeIntervalSince1970:1),isDirectory:true),"d/keep":r("d/keep","k"),"d/gone":r("d/gone","g"),"d/edit":r("d/edit","e"),"d/old":r("d/old","o")])
  let new=Snapshot(root:root,files:["d":FileRecord(path:"d",fileID:"D",size:0,modificationDate:Date(timeIntervalSince1970:1),isDirectory:true),"d/keep":r("d/keep","k"),"d/edit":r("d/edit","e",9),"d/new":r("d/new","n"),"d/renamed":r("d/renamed","o")])
  let diff=DirectoryTreeDiff.build(rootPath:"/x/proj",baseline:old,current:new)
  func find(_ n:TreeNode,_ id:String)->TreeNode?{if n.id==id{return n};for c in n.children{if let f=find(c,id){return f}};return nil}
  XCTAssertEqual(find(diff.original,"d/gone")?.status,.unchanged)
  XCTAssertEqual(find(diff.original,"d/old")?.status,.unchanged)
  XCTAssertEqual(find(diff.original,"d/edit")?.status,.unchanged)
  XCTAssertNil(find(diff.original,"d/new"))
  XCTAssertEqual(find(diff.modified,"d/new")?.status,.created)
  XCTAssertEqual(find(diff.modified,"d/renamed")?.status,.renamed)
  XCTAssertEqual(find(diff.modified,"d/gone")?.status,.deleted)
  XCTAssertEqual(find(diff.modified,"d/gone")?.isGhost,true)
  XCTAssertEqual(diff.summary.counts[.create],1);XCTAssertEqual(diff.summary.counts[.delete],1);XCTAssertEqual(diff.summary.counts[.modify],1);XCTAssertEqual(diff.summary.counts[.rename],1)
  XCTAssertEqual(diff.original.changedDescendants,3)
 }
 func testRepeatedModificationsOfOneItemAreAllKept(){
  let old=Snapshot(root:root,files:["f":r("f","1")]);let new=Snapshot(root:root,files:["g":r("g","1",30)])
  let t0=Date(timeIntervalSince1970:100)
  let history=[ChangeEvent(kind:.modify,path:"f",fileID:"1",previousSize:1,currentSize:10,contentChanged:true,observedAt:t0),
               ChangeEvent(kind:.modify,path:"f",fileID:"1",previousSize:10,currentSize:20,contentChanged:true,observedAt:t0+1),
               ChangeEvent(kind:.rename,oldPath:"f",path:"g",fileID:"1",previousSize:20,currentSize:20,observedAt:t0+2),
               ChangeEvent(kind:.modify,path:"g",fileID:"1",previousSize:20,currentSize:30,contentChanged:true,observedAt:t0+3)]
  let diff=DirectoryTreeDiff.build(rootPath:"/x",baseline:old,current:new,history:history)
  XCTAssertEqual(diff.modified.children.first?.history.count,4)
  XCTAssertEqual(diff.original.children.first?.history.count,4)
  XCTAssertEqual(diff.summary.counts[.modify],3);XCTAssertEqual(diff.summary.counts[.rename],1);XCTAssertEqual(diff.summary.itemCount,1)
  XCTAssertEqual(diff.summary.entries.count,4)
 }
 func testCreatedThenDeletedItemIsStillShown(){
  let base=Snapshot(root:root,files:[:]);let t0=Date(timeIntervalSince1970:100)
  let history=[ChangeEvent(kind:.create,path:"tmp",fileID:"9",currentSize:1,observedAt:t0),ChangeEvent(kind:.delete,path:"tmp",fileID:"9",previousSize:1,observedAt:t0+1)]
  let diff=DirectoryTreeDiff.build(rootPath:"/x",baseline:base,current:base,history:history)
  XCTAssertEqual(diff.modified.children.first?.isGhost,true);XCTAssertEqual(diff.modified.children.first?.history.count,2)
 }
 func testHiddenAndHash()throws{let d=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:d)};try Data("x".utf8).write(to:d.appendingPathComponent(".hidden"));let s=try Snapshotter.takeValidated(root:d,hashContents:true);XCTAssertNotNil(s.files[".hidden"]?.contentHash)}
 func testValidatedSnapshotRejectsUnavailableRoot(){let missing=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);XCTAssertThrowsError(try Snapshotter.takeValidated(root:missing))}
 func testSQLiteAndAlert()async throws{let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);let store=try ChangeStore(url:u);let c=AttributedChange(change:ChangeEvent(kind:.create,path:"a",fileID:"1"));try store.insert(c);let p=MockWhatsAppProvider();try await p.send(AlertAggregator().message(for:[c]));XCTAssertEqual(await p.messages.count,1);try? FileManager.default.removeItem(at:u)}
}
#else
import Foundation
@testable import ChangeLinkCore
func _changeLinkChecks(){let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);_ = try? ChangeStore(url:u);try? FileManager.default.removeItem(at:u)}
#endif
