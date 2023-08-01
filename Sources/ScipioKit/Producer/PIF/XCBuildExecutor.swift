import Logging
import TSCBasic
import PackageGraph
import XCBuildSupport

struct XCBuildExecutor {

    var xcbuildPath: AbsolutePath

    func build(
        pifPath: AbsolutePath,
        configuration: BuildConfiguration,
        derivedDataPath: AbsolutePath,
        buildParametersPath: AbsolutePath,
        target: ResolvedTarget
    ) async throws {
        let executor = _Executor(args: [
            xcbuildPath.pathString,
            "build",
            pifPath.pathString,
            "--configuration",
            configuration.settingsValue,
            "--derivedDataPath",
            derivedDataPath.pathString,
            "--buildParametersFile",
            buildParametersPath.pathString,
            "--target",
            target.name,
        ])
        try await executor.run()
    }
}

private final class _Executor {
    init(args: [String]) {
        self.args = args

        let parserDelegate = ParserDelegate()

        self.parser = XCBuildOutputParser(delegate: parserDelegate)
        self.parserDelegate = parserDelegate

        self.executor = ProcessExecutor<StandardErrorOutputDecoder>()

        executor.streamOutput = { [weak self] (bytes) in
            self?.parser.parse(bytes: bytes)
        }
        executor.collectsOutput = false

        parserDelegate.didParse = { [weak self] (message) in
            self?.handle(message: message)
        }
        parserDelegate.didFail = { [weak self] (error) in
            self?.parseError = error
            logger.error("xcbuild output parse failed", metadata: .color(.red))
            logger.error(error)
        }
    }

    let args: [String]

    let parser: XCBuildOutputParser
    let parserDelegate: ParserDelegate
    var executor: ProcessExecutor<StandardErrorOutputDecoder>

    // FIXME: store log on file
    var allMessages: [String] = []

    var parseError: Error?
    var executeError: Error?

    var targets: [Int: XCBuildMessage.TargetStartedInfo] = [:]
    var tasks: [Int: XCBuildMessage.TaskStartedInfo] = [:]

    func run() async throws {
        do {
            _ = try await executor.execute(args)
        } catch let error as ProcessExecutorError {
            switch error {
            case .signalled, .unknownError: throw error
            case .terminated:
                let output = allMessages.joined(separator: "\n")
                throw ProcessExecutorError.terminated(errorOutput: output)
            }
        } catch {
            throw ProcessExecutorError.unknownError(error)
        }

        if let parseError {
            throw ProcessExecutorError.unknownError(parseError)
        }
    }

    private func handle(message: XCBuildMessage) {
        switch message {
        case .buildStarted: break
        case .buildDiagnostic(let info):
            log(info.message)
        case .buildOutput(let info):
            log(info.data)
        case .buildCompleted(let info):
            switch info.result {
            case .ok: log("build completed")
            case .failed: log(level: .error, "build failed")
            case .cancelled: log(level: .error, "build cancelled")
            case .aborted: log(level: .error, "build aborted")
            }
        case .preparationComplete: break
        case .didUpdateProgress: break
        case .targetUpToDate: break
        case .targetStarted(let info):
            targets[info.targetID] = info
            log(target: info.targetName, "started")
        case .targetDiagnostic(let info):
            guard let target = targets[info.targetID] else { return }
            log(target: target.targetName, info.message)
        case .targetComplete(let info):
            guard let target = targets[info.targetID] else { return }
            log(target: target.targetName, "completed")
        case .taskUpToDate: break
        case .taskStarted(let info):
            tasks[info.taskID] = info
            let target = info.targetID.flatMap { targets[$0] }

            log(target: target?.targetName, task: info.taskID, info.executionDescription)
            if let commandLine = info.commandLineDisplayString {
                log(commandLine)
            }
        case .taskDiagnostic(let info):
            guard let task = tasks[info.taskID] else { return }
            let target = task.targetID.flatMap { targets[$0] }?.targetName
            log(target: target, task: task.taskID, info.message)
        case .taskOutput(let info):
            guard let task = tasks[info.taskID] else { return }
            let target = task.targetID.flatMap { targets[$0] }?.targetName
            log(target: target, task: task.taskID, info.data)
        case .taskComplete(let info):
            guard let task = tasks[info.taskID] else { return }
            let target = task.targetID.flatMap { targets[$0] }?.targetName

            switch info.result {
            case .success: break
            case .failed:
                log(level: .error, target: target, task: task.taskID, "failed")
            case .cancelled:
                log(level: .error, target: target, task: task.taskID, "cancelled")
            }
        }
    }

    private func log(
        level: Logger.Level = .info,
        target: String? = nil,
        task: Int? = nil,
        _ message: String
    ) {
        let label: String? = {
            var str = ""
            if let target {
                str += target
            }
            if let task {
                str += "#" + task.description
            }
            if str.isEmpty { return nil }
            return "[" + str + "]"
        }()

        var str = ""
        if let label {
            str += label + " "
        }
        str += message

        allMessages.append(str)
        logger.log(level: level, "\(str)")
    }
}

private final class ParserDelegate: XCBuildOutputParserDelegate {
    var didParse: ((XCBuildMessage) -> Void)?
    var didFail: ((Error) -> Void)?

    func xcBuildOutputParser(_ parser: XCBuildOutputParser, didParse message: XCBuildMessage) {
        didParse?(message)
    }

    func xcBuildOutputParser(_ parser: XCBuildOutputParser, didFailWith error: Error) {
        didFail?(error)
    }
}
