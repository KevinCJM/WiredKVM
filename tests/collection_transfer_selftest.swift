#if WK_TREE
import Foundation
import CryptoKit

enum WKCollectionTransferSelfTest {
    struct Failure: Error { let reason: String }
    static func check(_ value: Bool, _ reason: String) throws { if !value { throw Failure(reason: reason) } }
    static func dataset(_ root: URL, _ label: String, _ seed: UInt8) throws -> (WKTransferTree, [String: URL]) {
        let dir = root.appendingPathComponent(label), nested = dir.appendingPathComponent("中文 sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("空目录"), withIntermediateDirectories: false)
        var paths: [String: URL] = [:]
        for n in 0..<220 {
            let name = String(format:"small-%03d.bin", n), url = nested.appendingPathComponent(name)
            try Data((0..<(n % 37)).map { UInt8(truncatingIfNeeded: $0) ^ seed }).write(to: url, options: .withoutOverwriting)
            paths[label+"/中文 sub/"+name] = url
        }
        let large = try CH32StreamTest.source(nested, "large.bin", 32*1024*1024+173, seed)
        paths[label+"/中文 sub/large.bin"] = large
        let extra = root.appendingPathComponent(label+"-extra.txt")
        try Data("second selection 📄".utf8).write(to: extra, options: .withoutOverwriting); paths[extra.lastPathComponent] = extra
        let tree = try WKTransferTree(urls: [dir, extra], job: WKTreeJob())
        return (tree, paths)
    }
    static func digest(_ file: WKReceivedFile, _ entry: WKTreeManifest.Entry) throws -> String {
        var hash = SHA256(), offset: UInt64 = 0
        while offset < entry.size {
            let part = try file.read(offset: entry.offset+offset, maximum: min(65536, Int(entry.size-offset)))
            hash.update(data: part); offset += UInt64(part.count)
        }
        return hash.finalize().map { String(format:"%02x", $0) }.joined()
    }
    static func run(_ root: URL) throws {
        let (treeA, filesA) = try dataset(root, "book", 0x34), (treeB, filesB) = try dataset(root, "mini", 0xa5)
        let aSource = try WKStreamSource(tree: treeA, nonce: "9101"), bSource = try WKStreamSource(tree: treeB, nonce: "9102")
        let (pipe, a, b) = CH32StreamTest.pair(root)
        var manifests: [String: WKTreeManifest] = [:], received: [String: WKReceivedFile] = [:], finished = Set<String>(), failures: [String] = []
        var prefixBeforeData = 0, arrived: [String: UInt64] = [:]
        a.onProgress = { id,done,_ in arrived[id]=done }; b.onProgress = a.onProgress
        // The manifest can now precede the first disk-progress callback. No
        // progress means zero acknowledged bytes, not a completed payload.
        a.onManifest = { id, m in manifests[id] = m; if received[id] == nil && (arrived[id] ?? 0) < m.size { prefixBeforeData += 1 } }; b.onManifest = a.onManifest
        a.onFile = { id, f in received[id] = f }; b.onFile = a.onFile
        a.onComplete = { finished.insert($0) }; b.onComplete = a.onComplete
        a.onFailure = { failures.append($0) }; b.onFailure = a.onFailure
        a.onFault = { failures.append(String(describing:$0)) }; b.onFault = a.onFault
        try a.add(aSource, now: 0); try b.expect(aSource.offer, now: 0)
        try b.add(bSource, now: 0); try a.expect(bSource.offer, now: 0)
        pipe.stalled = [true, true]
        var tick = 0
        while finished.count < 2 && tick < 100_000 && failures.isEmpty {
            if tick == 200 { pipe.stalled = [false,false]; pipe.readLimit = 509; pipe.writeLimit = 997 }
            if tick == 350 { pipe.readLimit = 65536; pipe.writeLimit = 65536 }
            a.step(now: Double(tick)*0.0001); pipe.probe(UInt32(tick)); b.step(now: Double(tick)*0.0001); tick += 1
        }
        try check(failures.isEmpty && finished.count == 2 && prefixBeforeData == 2,
                  "bidirectional collection incomplete: failures=\(failures) completed=\(finished.count) files=\(received.count) manifests=\(manifests.count) early=\(prefixBeforeData) ticks=\(tick) offsets=\(arrived.values.sorted())")
        try check(pipe.failures == 0 && pipe.probes == tick, "HID probe failed")
        var verified = 0
        for (source, expected) in [(aSource,filesA),(bSource,filesB)] {
            guard let manifest = manifests[source.offer.id], let file = received[source.offer.id] else { throw Failure(reason:"missing receive") }
            try check(manifest.roots.count == 2 && manifest.entries.contains(where: { $0.path.hasSuffix("空目录") && $0.directory }), "roots or empty directory lost")
            for entry in manifest.entries where !entry.directory {
                guard let path = expected[entry.path] else { throw Failure(reason:"unexpected path") }
                let receivedHash = try digest(file,entry), originalHash = try CH32StreamTest.digest(path)
                try check(receivedHash == originalHash, "entry hash mismatch \(entry.path)"); verified += 1
            }
            try check(file.sha256 == CH32StreamTest.digest(file), "whole stream digest")
        }
        try cancellation(root)
        try emptyTree(root)
        if CommandLine.arguments.contains("--collection-http") {
            try http(offer:aSource.offer,manifest:manifests[aSource.offer.id]!,file:received[aSource.offer.id]!,expected:filesA)
        }
        let evidence: [String:Any] = ["test":"Rust tree source + Swift stream engines + C USB bridge simulator", "physicalUSB":false,
            "bytesAtoB":treeA.size,"bytesBtoA":treeB.size,"filesHashVerified":verified,"earlyManifests":prefixBeforeData,
            "hidProbes":pipe.probes,"hidFailures":pipe.failures,"hostBufferPeakA":a.maxBuffered,"hostBufferPeakB":b.maxBuffered,
            "generalClipboardAccess":false,"folderPasteIntegration":false,"cancellationRetry":true]
        let bytes = try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]); print(String(decoding:bytes,as:UTF8.self))
        if let i = CommandLine.arguments.firstIndex(of:"--json"), i+1 < CommandLine.arguments.count { try bytes.write(to:URL(fileURLWithPath:CommandLine.arguments[i+1]),options:.withoutOverwriting) }
    }
    static func cancellation(_ root: URL) throws {
        let (tree, _) = try dataset(root,"cancel",0x55), source = try WKStreamSource(tree: tree,nonce:"9201")
        let (pipe,a,b)=CH32StreamTest.pair(root); var files:Set<String>=[], failures:[String]=[]
        b.onFile = { files.insert($0); _ = $1 }; a.onFault={failures.append(String(describing:$0))};b.onFault=a.onFault
        try a.add(source,now:0);try b.expect(source.offer,now:0)
        for n in 0..<20 { a.step(now:Double(n)*0.001);b.step(now:Double(n)*0.001) }
        a.cancel(source.offer.id);b.cancel(source.offer.id)
        try check(!tree.unchanged(),"cancellation did not stop source work")
        let u=root.appendingPathComponent("fresh.txt");try Data("fresh".utf8).write(to:u,options:.withoutOverwriting)
        let freshTree=try WKTransferTree(urls:[u],job:WKTreeJob()), next=try WKStreamSource(tree:freshTree,nonce:"9202")
        try a.add(next,now:0.02);try b.expect(next.offer,now:0.02)
        var ticks=0
        while !files.contains(next.offer.id) && ticks<300 {
            let now=0.02+Double(ticks)*0.001;a.step(now:now);pipe.probe(UInt32(ticks));b.step(now:now);ticks+=1
        }
        try check(files == [next.offer.id] && failures.isEmpty && pipe.failures == 0,"cancel/retry failed")
        print("COLLECTION_CANCEL_RETRY_TICKS \(ticks)")
    }
    static func emptyTree(_ root:URL) throws {
        let dir=root.appendingPathComponent("only-empty");try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
        let tree=try WKTransferTree(urls:[dir],job:WKTreeJob()), s=try WKStreamSource(tree:tree,nonce:"9301")
        let (_,a,b)=CH32StreamTest.pair(root);var events:[String]=[]
        b.onManifest={_,_ in events.append("manifest")};b.onFile={_,_ in events.append("file")}
        try a.add(s,now:0);try b.expect(s.offer,now:0)
        for n in 0..<100 {a.step(now:Double(n)*0.001);b.step(now:Double(n)*0.001)}
        try check(events == ["manifest","file"],"empty tree did not finish in order")
    }
    static func http(offer: WKStreamOffer, manifest: WKTreeManifest, file: WKReceivedFile, expected: [String: URL]) throws {
        let store=WKPortalStore(), server=WKPortalHTTPServer(store:WKPortalStore(),proxyCheck:{_ in true})
        // A single actual store backs both metadata and verified ranges.
        _=server
        let http=WKPortalHTTPServer(store:store,proxyCheck:{_ in true});try http.start();defer{http.stop();store.stop()}
        try store.offerTree(id:offer.id,manifest:manifest,sha256:offer.manifestSHA256!)
        let base=http.url.appendingPathComponent(offer.id,isDirectory:true)
        let list=try WKFilePortalSelfTest.request(base,"PROPFIND",headers:["Depth":"1"])
        try check(list.status==207 && String(decoding:list.body,as:UTF8.self).contains("book-extra.txt"),"root PROPFIND")
        let dir=base.appendingPathComponent("book/中文 sub",isDirectory:true)
        let children=try WKFilePortalSelfTest.request(dir,"PROPFIND",headers:["Depth":"1"])
        try check(children.status==207 && String(decoding:children.body,as:UTF8.self).contains("large.bin"),"nested PROPFIND")
        let leaf=dir.appendingPathComponent("large.bin")
        let head=try WKFilePortalSelfTest.request(leaf,"HEAD")
        try check(head.status==200 && head.headers["content-length"]==String(32*1024*1024+173),"HEAD before body")
        try store.fulfill(id:offer.id,file:file)
        let response=try WKFilePortalSelfTest.request(leaf,headers:["Range":"bytes=0-8"])
        let original=try FileHandle(forReadingFrom:expected["book/中文 sub/large.bin"]!);defer{try? original.close()}
        try check(response.status==206 && response.body==original.read(upToCount:9),"tree range bytes")
        let zero=try WKFilePortalSelfTest.request(dir.appendingPathComponent("small-000.bin"))
        try check(zero.status==200 && zero.body.isEmpty,"empty file GET")
        let traversal=try WKFilePortalSelfTest.request(base,target:"/\(http.capability)/\(offer.id)/book/%2e%2e/escape")
        try check(traversal.status==404,"tree traversal")
        let directoryGet=try WKFilePortalSelfTest.request(dir)
        try check(directoryGet.status==405,"directory content request")
        print("COLLECTION_HTTP_PASS root=true nested=true headBeforeBody=true range=true empty=true traversalRejected=true")
    }
}
#endif
