// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Network
import SwiftUI
import UIKit

// Wi-Fi controllers: other phones on the same network become players 2-4.
// Madeira serves a gamepad page over HTTP (port 8765); the page opens a
// WebSocket (port 8766), sends the session token, and then a 12-byte state on
// every change and once a second. Each phone takes a free XInput slot through
// GamepadInput.claimRemoteSlot, so a game sees it as one more Xbox controller.
// No app is needed on the other phones: they scan the QR code in Settings.
// The token keeps other devices on the network from joining unasked; it changes
// every time the switch is turned on. Log tag: [remote-pad].

final class RemotePadServer: ObservableObject, @unchecked Sendable {
    static let shared = RemotePadServer()
    static let enabledKey = "madeiraRemotePads"
    static let httpPort: UInt16 = 8765
    static let socketPort: UInt16 = 8766

    struct Player: Identifiable, Equatable {
        let id: UUID
        let slot: Int
        var name: String
    }

    @Published private(set) var running = false
    @Published private(set) var players: [Player] = []
    @Published private(set) var address: String?
    @Published private(set) var problem: String?

    private let queue = DispatchQueue(label: "madeira.remote-pads")
    private var http: NWListener?
    private var socket: NWListener?
    private var token = ""
    /// Per connection: its slot once the token was accepted, and when it last spoke.
    private var sessions: [ObjectIdentifier: (connection: NWConnection, player: Player?, last: Date)] = [:]
    private var watchdog: DispatchSourceTimer?
    /// The first few non-idle states, so a log shows input arriving.
    private var pressLog = 0
    /// The slot each phone (by its page's device id) last had, on `queue`.
    private var lastSlot: [String: Int] = [:]

    var joinURL: URL? {
        guard let address, running else { return nil }
        return URL(string: "http://\(address):\(Self.httpPort)/?t=\(token)")
    }

    /// At launch: resume the switch's last state.
    @MainActor func restore() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    @MainActor func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        on ? start() : stop()
    }

    @MainActor func start() {
        guard !running else { return }
        token = String((0..<6).map { _ in "abcdefghjkmnpqrstuvwxyz23456789".randomElement()! })
        address = Self.localAddress()
        problem = address == nil ? "Connect this iPhone to Wi-Fi (or turn on its Personal Hotspot) so other phones can reach it." : nil
        do {
            let httpListener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.httpPort)!)
            httpListener.newConnectionHandler = { [weak self] c in self?.serveHTTP(c) }
            httpListener.stateUpdateHandler = { [weak self] s in self?.listenerState("http", s) }
            httpListener.start(queue: queue)

            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            let params = NWParameters.tcp
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            let socketListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.socketPort)!)
            socketListener.newConnectionHandler = { [weak self] c in self?.accept(c) }
            socketListener.stateUpdateHandler = { [weak self] s in self?.listenerState("ws", s) }
            socketListener.start(queue: queue)

            http = httpListener
            socket = socketListener
            running = true
            GamepadInput.shared.reserveRemoteSlots(true)
            startWatchdog()
            LogStore.shared.log("[remote-pad] listening reachable=\(address != nil ? 1 : 0)")
        } catch {
            problem = "Rig couldn't open its controller port: \(error.localizedDescription)"
            LogStore.shared.log("[remote-pad] listen failed: \(error.localizedDescription)", level: .error)
        }
    }

    @MainActor func stop() {
        http?.cancel(); socket?.cancel()
        http = nil; socket = nil
        watchdog?.cancel(); watchdog = nil
        queue.async { [self] in
            for (_, s) in sessions { drop(s.connection) }
            sessions.removeAll()
        }
        running = false
        players = []
        GamepadInput.shared.reserveRemoteSlots(false)
        LogStore.shared.log("[remote-pad] stopped")
    }

    private func listenerState(_ which: String, _ state: NWListener.State) {
        if case .failed(let error) = state {
            LogStore.shared.log("[remote-pad] \(which) listener failed: \(error)", level: .error)
            DispatchQueue.main.async { self.problem = "The controller server stopped: \(error.localizedDescription). Turn it off and on." }
        }
    }

    // MARK: HTTP: the gamepad page

    private func serveHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let firstLine = request.split(separator: "\r\n").first ?? ""
            let ok = firstLine.hasPrefix("GET / ") || firstLine.hasPrefix("GET /?")
            let body = ok ? Self.page(socketPort: Self.socketPort) : "Not found"
            let head = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: \(ok ? "text/html; charset=utf-8" : "text/plain")\r\n"
                + "Cache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    // MARK: WebSocket: the players

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        sessions[key] = (connection, nil, Date())
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.drop(connection) }
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { drop(connection); return }
            let key = ObjectIdentifier(connection)
            let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
            if opcode == .close { drop(connection); return }
            if let data, var session = sessions[key] {
                session.last = Date()
                if session.player == nil {
                    // The first message is "token|name|device id" (the id the page keeps
                    // in localStorage, so a phone that reconnects gets its slot back).
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let parts = text.split(separator: "|", maxSplits: 2).map(String.init)
                    let device = parts.count > 2 ? String(parts[2].prefix(40)) : ""
                    guard parts.first == token else {
                        send("denied", to: connection)
                        LogStore.shared.log("[remote-pad] refused a phone with the wrong code")
                        drop(connection); return
                    }
                    guard let slot = GamepadInput.shared.claimRemoteSlot(preferred: lastSlot[device]) else {
                        send("full", to: connection)
                        drop(connection); return
                    }
                    let name = String((parts.count > 1 ? parts[1] : "").prefix(24))
                    let player = Player(id: UUID(), slot: slot, name: name.isEmpty ? "Phone" : name)
                    session.player = player
                    sessions[key] = session
                    if !device.isEmpty { lastSlot[device] = slot }
                    send("player \(slot + 1)", to: connection)
                    publishPlayers()
                    LogStore.shared.log("[remote-pad] player \(slot + 1) joined")
                } else if data.count == 12, let player = session.player {
                    sessions[key] = session
                    let sample = Self.decode(data)
                    if sample != GamepadSample(), pressLog < 8 {
                        pressLog += 1
                        LogStore.shared.log("[remote-pad] player \(player.slot + 1) input buttons=0x\(String(sample.buttons, radix: 16)) lx=\(sample.lx) ly=\(sample.ly)")
                    }
                    GamepadInput.shared.setRemote(slot: player.slot, sample: sample)
                } else {
                    sessions[key] = session
                }
            }
            receive(on: connection)
        }
    }

    private func send(_ text: String, to connection: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }

    /// Ends a connection and frees its slot. On `queue`.
    private func drop(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard let session = sessions.removeValue(forKey: key) else { return }
        connection.cancel()
        if let player = session.player {
            GamepadInput.shared.releaseRemoteSlot(player.slot)
            LogStore.shared.log("[remote-pad] player \(player.slot + 1) left")
            publishPlayers()
        }
    }

    /// A phone that locks or leaves Wi-Fi stops sending without closing; the page
    /// repeats its state every second, so 10 s of silence means it is gone
    /// (Safari can hold a page's timers back for a few seconds).
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stale = sessions.values.filter { Date().timeIntervalSince($0.last) > 10 }.map(\.connection)
            stale.forEach(drop)
        }
        timer.resume()
        watchdog = timer
    }

    private func publishPlayers() {
        let list = sessions.values.compactMap(\.player).sorted { $0.slot < $1.slot }
        DispatchQueue.main.async { self.players = list }
    }

    /// buttons u16, lt u8, rt u8, lx ly rx ry i16, little-endian (the page's layout).
    static func decode(_ data: Data) -> GamepadSample {
        let b = [UInt8](data)
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
        var s = GamepadSample()
        s.buttons = u16(0)
        s.lt = b[2]; s.rt = b[3]
        s.lx = Int16(bitPattern: u16(4)); s.ly = Int16(bitPattern: u16(6))
        s.rx = Int16(bitPattern: u16(8)); s.ry = Int16(bitPattern: u16(10))
        return s
    }

    /// This iPhone's IPv4 address on Wi-Fi (en0) or its Personal Hotspot (bridge*).
    static func localAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: [String: String] = [:]
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found[name] = String(cString: host)
            }
        }
        return found["en0"] ?? found.first(where: { $0.key.hasPrefix("bridge") })?.value
    }

    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Settings

/// Settings › Wi-Fi controllers.
struct RemotePadSettingsSection: View {
    @ObservedObject private var server = RemotePadServer.shared

    var body: some View {
        Section {
            Toggle("Wi-Fi controllers", isOn: Binding(get: { server.running }, set: { server.setEnabled($0) }))
            if server.running {
                if let url = server.joinURL {
                    HStack {
                        Spacer()
                        if let image = RemotePadServer.qrImage(url.absoluteString) {
                            Image(uiImage: image).interpolation(.none).resizable()
                                .frame(width: 180, height: 180)
                                .accessibilityLabel("QR code to join as a controller")
                        }
                        Spacer()
                    }
                    LabeledContent("Address", value: url.absoluteString)
                        .textSelection(.enabled)
                }
                if let problem = server.problem {
                    Label(problem, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                }
                if server.players.isEmpty {
                    Text("No phones connected yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(server.players) { player in
                        Label("Player \(player.slot + 1): \(player.name)", systemImage: "gamecontroller.fill")
                    }
                }
            }
        } header: { Text("Wi-Fi controllers") } footer: {
            Text("Other phones on the same Wi-Fi become players 2 to 4: they scan the code with the Camera and play in Safari, no app needed. Games see each one as an Xbox controller. Player 1 is this iPhone's touch controls or its own controller.")
        }
    }
}

// MARK: - The gamepad page

extension RemotePadServer {
    static func page(socketPort: UInt16) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <title>Madeira controller</title>
        <style>
        :root{color-scheme:dark}
        *{box-sizing:border-box;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;touch-action:none}
        html,body{margin:0;height:100%;background:#111;color:#eee;font:600 15px -apple-system,system-ui;overflow:hidden}
        #status{position:fixed;top:max(8px,env(safe-area-inset-top));left:0;right:0;text-align:center;opacity:.8}
        #rotate{display:none;position:fixed;inset:0;align-items:center;justify-content:center;font-size:20px;text-align:center;padding:24px}
        @media (orientation:portrait){#rotate{display:flex}#pad{display:none}}
        #pad{position:fixed;inset:0}
        .b{position:absolute;display:flex;align-items:center;justify-content:center;border-radius:50%;
           background:#2a2a2e;border:2px solid #444;font-size:18px}
        .b.on{background:#5a5a66;border-color:#999}
        .stick{position:absolute;border-radius:50%;background:#1d1d21;border:2px solid #3a3a40}
        .knob{position:absolute;width:44%;height:44%;left:28%;top:28%;border-radius:50%;background:#55555f}
        .sq{border-radius:10px}
        </style></head><body>
        <div id="status">Connecting…</div>
        <div id="rotate">Turn your phone sideways to play.</div>
        <div id="pad"></div>
        <script>
        const M={up:1,down:2,left:4,right:8,start:16,back:32,ls:64,rs:128,lb:256,rb:512,a:4096,b:8192,x:16384,y:32768};
        const st={buttons:0,lt:0,rt:0,lx:0,ly:0,rx:0,ry:0};
        const pad=document.getElementById('pad'),status=document.getElementById('status');
        function el(cls,txt,css){const d=document.createElement('div');d.className=cls;if(txt)d.textContent=txt;Object.assign(d.style,css);pad.appendChild(d);return d}
        function vw(p){return p*innerWidth/100} function vh(p){return p*innerHeight/100}
        const buttons=[];
        function button(name,txt,x,y,s,cls){const d=el('b'+(cls?' '+cls:''),txt,{});buttons.push({d,name,x,y,s});return d}
        button('lt','LT',4,4,16,'sq');button('lb','LB',22,4,16,'sq');button('rb','RB',62,4,16,'sq');button('rt','RT',80,4,16,'sq');
        button('back','⧉',40,5,10);button('start','☰',52,5,10);
        button('y','Y',80,26,15);button('x','X',70,44,15);button('b','B',90,44,15);button('a','A',80,62,15);
        button('up','▲',20,58,9,'sq');button('left','◀',11,72,9,'sq');button('right','▶',29,72,9,'sq');button('down','▼',20,86,9,'sq');
        button('ls','L3',40,86,7);button('rs','R3',53,86,7);
        const sticks=[{name:'l',x:16,y:36,s:22},{name:'r',x:58,y:62,s:22}];
        sticks.forEach(k=>{k.d=el('stick','',{});k.knob=document.createElement('div');k.knob.className='knob';k.d.appendChild(k.knob)});
        function layout(){
          buttons.forEach(o=>{const s=vh(o.s),w=o.d.classList.contains('sq')&&o.name.length==2?s*1.6:s;
            Object.assign(o.d.style,{left:vw(o.x)+'px',top:vh(o.y)+'px',width:w+'px',height:s+'px'})});
          sticks.forEach(k=>{const s=vh(k.s*1.6);Object.assign(k.d.style,{left:vw(k.x)-s/2+'px',top:vh(k.y)-s/2+'px',width:s+'px',height:s+'px'})});
        }
        addEventListener('resize',layout);layout();
        const touches=new Map();
        function hit(t){
          for(const k of sticks){const r=k.d.getBoundingClientRect();const cx=r.left+r.width/2,cy=r.top+r.height/2;
            if(Math.hypot(t.clientX-cx,t.clientY-cy)<r.width*0.75)return{stick:k,cx,cy,rad:r.width/2}}
          for(const o of buttons){const r=o.d.getBoundingClientRect();const m=10;
            if(t.clientX>r.left-m&&t.clientX<r.right+m&&t.clientY>r.top-m&&t.clientY<r.bottom+m)return{button:o}}
          return null}
        function recompute(){
          let b=0,lt=0,rt=0,l=[0,0],r=[0,0];
          buttons.forEach(o=>o.d.classList.remove('on'));sticks.forEach(k=>k.knob.style.transform='');
          for(const h of touches.values()){
            if(h.button){const n=h.button.name;h.button.d.classList.add('on');
              if(n=='lt')lt=255;else if(n=='rt')rt=255;else b|=M[n]}
            if(h.stick){let dx=(h.x-h.cx)/h.rad,dy=(h.y-h.cy)/h.rad;const m=Math.hypot(dx,dy);if(m>1){dx/=m;dy/=m}
              h.stick.knob.style.transform=`translate(${dx*h.rad*0.6}px,${dy*h.rad*0.6}px)`;
              (h.stick.name=='l'?l:r).splice(0,2,dx,-dy)}}
          st.buttons=b;st.lt=lt;st.rt=rt;
          st.lx=Math.round(l[0]*32767);st.ly=Math.round(l[1]*32767);st.rx=Math.round(r[0]*32767);st.ry=Math.round(r[1]*32767);
          send()}
        function down(e){e.preventDefault();const h=hit(e);
          if(h)touches.set(e.pointerId,Object.assign(h,{x:e.clientX,y:e.clientY}));recompute()}
        function move(e){const h=touches.get(e.pointerId);if(!h)return;e.preventDefault();
          h.x=e.clientX;h.y=e.clientY;if(h.button){const n=hit(e);if(n&&n.button)h.button=n.button}recompute()}
        function up(e){if(touches.delete(e.pointerId))recompute()}
        pad.addEventListener('pointerdown',down);
        addEventListener('pointermove',move);
        addEventListener('pointerup',up);addEventListener('pointercancel',up);
        // Safari still scrolls or zooms on a touch the page does not cancel.
        ['touchstart','touchmove'].forEach(n=>document.addEventListener(n,e=>e.preventDefault(),{passive:false}));
        let ws,last='';
        function send(force){if(!ws||ws.readyState!=1||!joined)return;
          const buf=new ArrayBuffer(12),v=new DataView(buf);
          v.setUint16(0,st.buttons,true);v.setUint8(2,st.lt);v.setUint8(3,st.rt);
          v.setInt16(4,st.lx,true);v.setInt16(6,st.ly,true);v.setInt16(8,st.rx,true);v.setInt16(10,st.ry,true);
          const key=new Uint8Array(buf).join(',');if(!force&&key==last)return;last=key;ws.send(buf)}
        let joined=false;
        function connect(){
          const token=new URLSearchParams(location.search).get('t')||'';
          ws=new WebSocket(`ws://${location.hostname}:\(socketPort)/`);ws.binaryType='arraybuffer';
          let id=localStorage.getItem('madeira-pad-id');
          if(!id){id=Math.random().toString(36).slice(2,12);localStorage.setItem('madeira-pad-id',id)}
          ws.onopen=()=>{ws.send(token+'|'+(navigator.platform||'Phone')+'|'+id)};
          ws.onmessage=e=>{const m=String(e.data);
            if(m.startsWith('player')){joined=true;status.textContent='You are '+m.replace('player','Player');send(true)}
            else if(m=='full')status.textContent='All controller slots are taken.';
            else if(m=='denied')status.textContent='This code is out of date. Scan the QR code again.'};
          ws.onclose=()=>{joined=false;if(!/taken|out of date/.test(status.textContent)){status.textContent='Reconnecting…';setTimeout(connect,1500)}}}
        connect();
        setInterval(()=>send(true),1000);
        </script></body></html>
        """
    }
}
