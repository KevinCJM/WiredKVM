// Injected login registration and unmount callbacks; never registers a login
// item, opens settings, reads the general pasteboard, or accesses a USB device.
import AppKit
import Foundation

@main enum OnboardingSelfTest {
    @MainActor static func main() {
        var count = 0
        func check(_ name: String, _ test: () -> Void) { test(); count += 1; print("ONBOARDING \(name) PASS") }
        check("role-interface-identity-not-arbitrary-serial") {
            precondition(WKUSBDiscovery.accepts(vendor:0x1a86,product:0x4070,serial:"CH32V407-DoNotShip",interface:0))
            for (v,p,s,i) in [(0x303a,0x4070,"CH32V407-DoNotShip",0),(0x1a86,0x4070,"other",0),(0x1a86,0x4070,"CH32V407-DoNotShip",4),(0x1a86,0x4071,"CH32V407-DoNotShip",5)] {
                precondition(!WKUSBDiscovery.accepts(vendor:v,product:p,serial:s,interface:i))
            }
        }
        check("each-role-discovered-without-other-computer") {
            let a=WKUSBDiscovery.Port(path:"/dev/cu.host-control",serial:"fixture",product:0x4070,interface:0)
            let b=WKUSBDiscovery.Port(path:"/dev/cu.host-files",serial:"fixture",product:0x4070,interface:2)
            let c=WKUSBDiscovery.Port(path:"/dev/cu.target-files",serial:"fixture",product:0x4071,interface:3)
            precondition(WKUSBDiscovery.unique(role:"host",files:false,inventory:[a,b])==a.path)
            precondition(WKUSBDiscovery.unique(role:"host",files:true,inventory:[a,b])==b.path)
            precondition(WKUSBDiscovery.unique(role:"target",files:true,inventory:[c])==c.path)
            let d=WKUSBDiscovery.Port(path:"/dev/cu.other",serial:"fixture2",product:0x4070,interface:0)
            precondition(WKUSBDiscovery.unique(role:"host",files:false,inventory:[a,d])==nil)
        }
        check("grace-one-offer-per-connection-and-user-pause") {
            var p=WKSetupOfferPolicy();p.reset(at:100)
            precondition(!p.shouldOffer(at:104.99,enabled:true,paused:false))
            precondition(!p.shouldOffer(at:106,enabled:true,paused:true))
            precondition(p.shouldOffer(at:106,enabled:true,paused:false))
            precondition(!p.shouldOffer(at:200,enabled:true,paused:false))
            p.reset(at:201);p.observe(connected:true,compatible:true)
            precondition(!p.shouldOffer(at:210,enabled:true,paused:false))
            p.observe(connected:false,compatible:false)
            precondition(!p.shouldOffer(at:220,enabled:true,paused:false))
        }
        check("old-or-missing-component-offers-new-epoch-only") {
            var p=WKSetupOfferPolicy();p.reset(at:1);p.observe(connected:true,compatible:false)
            precondition(p.shouldOffer(at:6,enabled:true,paused:false))
            p.reset(at:nil);precondition(!p.shouldOffer(at:100,enabled:true,paused:false))
            p.reset(at:101);precondition(p.shouldOffer(at:106,enabled:true,paused:false))
        }
        check("login-choice-never-overridden-on-reconnect-or-reinstall") {
            let name="wk-login-test-"+UUID().uuidString;let defaults=UserDefaults(suiteName:name)!
            defer { defaults.removePersistentDomain(forName:name) }
            var calls=0
            precondition(WKLoginItem.configureOnce(defaults:defaults,register:{calls+=1})==nil)
            precondition(WKLoginItem.configureOnce(defaults:defaults,register:{calls+=1})==nil&&calls==1)
        }
        check("failed-login-shows-failure-without-repeated-prompts") {
            let name="wk-login-error-"+UUID().uuidString;let defaults=UserDefaults(suiteName:name)!
            defer { defaults.removePersistentDomain(forName:name) }
            var calls=0
            let error=WKLoginItem.configureOnce(defaults:defaults,register:{calls+=1;throw NSError(domain:"fixture",code:1)})
            precondition(error != nil)
            _=WKLoginItem.configureOnce(defaults:defaults,register:{calls+=1});precondition(calls==1)
        }
        check("presence-packet-standard-crc-and-independent-role") {
            precondition(WKSetupPacket.crc(Data("123456789".utf8))==0xcbf43926)
            let a=WKSetupPacket.encode(role:"host",hide:false,sequence:9),b=WKSetupPacket.encode(role:"target",hide:true,sequence:10)
            precondition(a.count==64&&b.count==64&&a[5]==0&&b[5]==1&&a[6]==1&&b[6]==2)
            precondition(a[8]==9&&b[8]==10)
        }
        check("fresh-input-policy-without-overwriting-prior-choice") {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("wk-policy-first-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:directory) }
            try! WKFirstRunDefaults.prepareInputPolicy(directory:directory)
            let path=directory.appendingPathComponent("input-mode.json")
            precondition(try! String(contentsOf:path).contains("gestures"))
            try! Data("{\"mode\":\"legacy\"}".utf8).write(to:path)
            try! WKFirstRunDefaults.prepareInputPolicy(directory:directory)
            precondition(try! String(contentsOf:path).contains("legacy"))
        }
        check("no-hide-before-safe-unmount-and-busy-volume-retry") {
            var packets:[Data]=[];var safe=false
            let lease=WKSetupLease(role:"target",send:{packets.append($0);return true},unmount:{_ in safe})
            func pump(){RunLoop.current.run(until:Date(timeIntervalSinceNow:0.05))}
            lease.tick(1);pump();lease.tick(2);pump();precondition(packets.allSatisfy{$0[6]==1})
            safe=true;lease.tick(3);pump();lease.tick(4);pump();precondition(packets.last![6]==2)
            precondition(packets.count==4)
        }
        print("ONBOARDING_SELFTEST_PASS count=\(count) login_mutated=false volumes_touched=false real_input=false")
    }
}
