import Foundation
import Logging
import Basics
import XCBuildSupport
import Algorithms

struct XCBuildExecutor {

    var xcbuildPath: URL

    func build(
        pifPath: TSCAbsolutePath,
        configuration: BuildConfiguration,
        derivedDataPath: TSCAbsolutePath,
        buildParametersPath: TSCAbsolutePath,
        target: ResolvedModule
    ) async throws {
        let executor = _Executor(args: [
            xcbuildPath.path(percentEncoded: false),
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
    private var allMessages: [String] = []

    private var parseError: Error?
    private var executeError: Error?

    private var targets: [Int: XCBuildMessage.TargetStartedInfo] = [:]
    private var tasks: [Int: XCBuildMessage.TaskStartedInfo] = [:]

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
        case .unknown:
            break
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
