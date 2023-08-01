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

        self.executor = ProcessExecutor<StandardErrorOutputDecoder>()

        self.parser = XCBuildOutputParser(delegate: self)

        executor.streamOutput = { [weak self] (bytes) in
            self?.parser.parse(bytes: bytes)
        }
        executor.collectsOutput = false
    }

    let args: [String]

    lazy var parser: XCBuildOutputParser = { preconditionFailure("uninitialized") }()
    var executor: ProcessExecutor<StandardErrorOutputDecoder>

    // FIXME: store log on file
    var allMessages: [String] = []

    var parseError: Error?
    var executeError: Error?

    var targets: [Int: XCBuildMessage.TargetStartedInfo] = [:]
    var tasks: [Int: XCBuildMessage.TaskStartedInfo] = [:]

    func run() async throws {
        precondition(
            allMessages.isEmpty &&
            targets.isEmpty,
            "this method can only be called once"
        )

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
            handleBuildDiagnostic(info: info)
        case .buildOutput(let info):
            handleBuildOutput(info: info)
        case .buildCompleted(let info):
            handleBuildCompleted(info: info)
        case .preparationComplete: break
        case .didUpdateProgress: break
        case .targetUpToDate: break
        case .targetStarted(let info):
            handleTargetStarted(info: info)
        case .targetDiagnostic(let info):
            handleTargetDiagnostic(info: info)
        case .targetComplete(let info):
            handleTargetComplete(info: info)
        case .taskUpToDate: break
        case .taskStarted(let info):
            handleTaskStarted(info: info)
        case .taskDiagnostic(let info):
            handleTaskDiagnostic(info: info)
        case .taskOutput(let info):
            handleTaskOutput(info: info)
        case .taskComplete(let info):
            handleTaskComplete(info: info)
        }
    }

    private func handleBuildDiagnostic(info: XCBuildMessage.BuildDiagnosticInfo) {
        log(info.message)
    }

    private func handleBuildOutput(info: XCBuildMessage.BuildOutputInfo) {
        log(info.data)
    }

    private func handleBuildCompleted(info: XCBuildMessage.BuildCompletedInfo) {
        switch info.result {
        case .ok: log("build completed")
        case .failed: log(level: .error, "build failed")
        case .cancelled: log(level: .error, "build cancelled")
        case .aborted: log(level: .error, "build aborted")
        }
    }

    private func handleTargetStarted(info: XCBuildMessage.TargetStartedInfo) {
        targets[info.targetID] = info
        log(target: info.targetName, "started")
    }

    private func handleTargetDiagnostic(info: XCBuildMessage.TargetDiagnosticInfo) {
        guard let target = targets[info.targetID] else { return }
        log(target: target.targetName, info.message)
    }

    private func handleTargetComplete(info: XCBuildMessage.TargetCompleteInfo) {
        guard let target = targets[info.targetID] else { return }
        log(target: target.targetName, "completed")
    }

    private func handleTaskStarted(info: XCBuildMessage.TaskStartedInfo) {
        tasks[info.taskID] = info
        let target = info.targetID.flatMap { targets[$0] }

        log(target: target?.targetName, task: info.taskID, info.executionDescription)
        if let commandLine = info.commandLineDisplayString {
            log(commandLine)
        }
    }

    private func handleTaskDiagnostic(info: XCBuildMessage.TaskDiagnosticInfo) {
        guard let task = tasks[info.taskID] else { return }
        let target = task.targetID.flatMap { targets[$0] }?.targetName
        log(target: target, task: task.taskID, info.message)
    }

    private func handleTaskOutput(info: XCBuildMessage.TaskOutputInfo) {
        guard let task = tasks[info.taskID] else { return }
        let target = task.targetID.flatMap { targets[$0] }?.targetName
        log(target: target, task: task.taskID, info.data)
    }

    private func handleTaskComplete(info: XCBuildMessage.TaskCompleteInfo) {
        guard let task = tasks[info.taskID] else { return }
        let target = task.targetID.flatMap { targets[$0] }?.targetName

        switch info.result {
        case .success: break
        case .failed:
            log(level: .error, target: target, task: task.taskID, "failed")
        case .cancelled:
            log(level: .error, target: target, task: task.taskID, "canceleld")
        }
    }

    private func log(
        level: Logger.Level = .trace,
        target: String? = nil,
        task: Int? = nil,
        _ message: String
    ) {
        let labelContent: String = [
            target,
            task.map { "#" + $0.description },
        ].compacted().joined()

        let label: String?
        if labelContent.isEmpty {
            label = nil
        } else {
            label = "[" + labelContent + "]"
        }

        let message = [
            label,
            message,
        ].compacted().joined(separator: " ")

        allMessages.append(message)
        logger.log(level: level, "\(message)")
    }
}

extension _Executor: XCBuildOutputParserDelegate {
    func xcBuildOutputParser(_ parser: XCBuildOutputParser, didParse message: XCBuildMessage) {
        handle(message: message)
    }

    func xcBuildOutputParser(_ parser: XCBuildOutputParser, didFailWith error: Error) {
        self.parseError = error
        logger.error("xcbuild output parse failed", metadata: .color(.red))
        logger.error(error)
    }
}
