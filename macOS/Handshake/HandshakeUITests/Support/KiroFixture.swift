import Foundation
import XCTest

struct KiroLaunch: Decodable {
    let session: String
    let profile: String
    let resumed: Bool
    let yolo: Bool
    let pid: Int32
}

extension HandshakeUITests {
    func writeKiroFixture(in folder: URL) throws {
        let bin = folder.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = #"""
            #!/usr/bin/python3
            import json,os,pathlib,subprocess,sys,uuid
            args=sys.argv[1:]
            if '--list-models' in args:
                sys.stdout.write(json.dumps({'models':[{'model_id':'fixture-fast','model_name':'Fast fixture model'}]}))
                sys.exit(0)
            def option(flag):
                return args[args.index(flag)+1] if flag in args else None
            profile=option('--agent')
            config=json.loads((pathlib.Path(os.environ['KIRO_HOME'])/'agents'/(profile+'.json')).read_text())
            session=option('--resume-id') or 'sess_'+uuid.uuid4().hex
            record={'session':session,'profile':profile,'resumed':'--resume-id' in args,
                'yolo':'--trust-all-tools' in args,'pid':os.getpid()}
            with open('kiro-launches.jsonl','a') as f: f.write(json.dumps(record)+'\n')
            def hook(event,**fields):
                payload={'hook_event_name':event,'session_id':session,**fields}
                for h in config['hooks']:
                    if h['trigger']==event:
                        subprocess.run(['/bin/sh','-c',h['action']['command']],
                                   input=json.dumps(payload).encode(),check=True)
            hook('SessionStart')
            sys.stdout.write('KIRO READY '+session+'\n'); sys.stdout.flush()
            for line in sys.stdin:
                prompt=line.strip()
                if not prompt: continue
                hook('UserPromptSubmit',prompt=prompt)
                hook('PreToolUse',tool_name='read_file',tool_input={'path':'fixture.txt'})
                hook('PostToolUse',tool_name='read_file',tool_input={'path':'fixture.txt'},
                 tool_response='Fixture tool output')
                sys.stdout.write('KIRO ANSWER '+prompt+'\n'); sys.stdout.flush()
                hook('Stop',last_assistant_message='Fixture answer')
                with open('kiro-input-'+session,'a') as f: f.write(prompt+'\n')
            """#
        let agent = folder.appending(path: "kiro-agent.py")
        try script.write(to: agent, atomically: true, encoding: .utf8)
        let command = bin.appending(path: "kiro-cli")
        let wrapper = """
            #!/bin/sh
            case "$*" in *--list-models*)
                printf '%s' '{"models":[{"model_id":"fixture-fast","model_name":"Fast fixture model"}]}'
                exit 0 ;;
            esac
            exec /usr/bin/python3 '\(agent.path)' "$@"
            """
        try wrapper.write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
    }

    func kiroLaunches(in folder: URL) -> [KiroLaunch] {
        let text = (try? String(contentsOf: folder.appending(path: "kiro-launches.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(KiroLaunch.self, from: Data($0.utf8))
        }
    }

    @MainActor
    func waitForKiroLaunches(_ count: Int, in folder: URL, app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.kiroLaunches(in: folder).count >= count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
    }
}
