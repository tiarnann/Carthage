import Foundation
import Result

public protocol CartfileProtocol {
    static var relativePath: String { get }
    static func from(fileURL: URL) -> Result<Self, CarthageError>
    static func from(string: String) -> Result<Self, CarthageError>
}

extension CartfileProtocol {
    /// Returns the location where Cartfile should exist within the given
    /// directory.
    public static func url(in directoryURL: URL) -> URL {
        return directoryURL.appendingPathComponent(self.relativePath, isDirectory: false)
    }

    public static func from(fileURL: URL) -> Result<Self, CarthageError> {
        return Result(catching: { try String(contentsOf: fileURL, encoding: .utf8) })
            .mapError { .readFailed(fileURL, $0) }
            .flatMap(self.from)
            .mapError { error in
                guard case let .duplicateDependencies(dupes) = error else { return error }
                let dependencies = dupes
                    .map { dupe in
                        return DuplicateDependency(
                            dependency: dupe.dependency,
                            locations: [ fileURL.path ]
                        )
                }
                return .duplicateDependencies(dependencies)
            }
    }

    public static func from(directoryURL: URL) -> Result<Self, CarthageError> {
        return from(fileURL: url(in: directoryURL))
    }
}

/// Represents a Cartfile, which is a specification of a project's dependencies
/// and any other settings Carthage needs to build it.
public struct Cartfile {
    /// Any text following this character is considered a comment
    static let commentIndicator = "#"

    /// The dependencies listed in the Cartfile.
    public var dependencies: [Dependency: VersionSpecifier]

    public init(dependencies: [Dependency: VersionSpecifier] = [:]) {
        self.dependencies = dependencies
    }

    /// Appends the contents of another Cartfile to that of the receiver.
    public mutating func append(_ cartfile: Cartfile) {
        for (dependency, version) in cartfile.dependencies {
            dependencies[dependency] = version
        }
    }
}

extension Cartfile: CartfileProtocol {
    public static var relativePath: String {
        return Constants.Project.cartfilePath
    }

    /// Attempts to parse Cartfile information from a string.
    public static func from(string: String) -> Result<Cartfile, CarthageError> {
        var dependencies: [Dependency: VersionSpecifier] = [:]
        var duplicates: [Dependency] = []
        var result: Result<(), CarthageError> = .success(())

        string.enumerateLines { line, stop in
            let scannerWithComments = Scanner(string: line)

            if scannerWithComments.scanString(Cartfile.commentIndicator, into: nil) {
                // Skip the rest of the line.
                return
            }

            if scannerWithComments.isAtEnd {
                // The line was all whitespace.
                return
            }

            guard let remainingString = scannerWithComments.remainingSubstring.map(String.init) else {
                result = .failure(CarthageError.internalError(
                    description: "Can NSScanner split an extended grapheme cluster? If it does, this will be the error…"
                ))
                stop = true
                return
            }

            let scannerWithoutComments = Scanner(
                string: remainingString.strippingTrailingCartfileComment
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            )

            switch Dependency.from(scannerWithoutComments).fanout(VersionSpecifier.from(scannerWithoutComments)) {
            case let .success((dependency, versionSpecifier)):
                if case .binary = dependency, case .gitReference = versionSpecifier {
                    result = .failure(
                        CarthageError.parseError(
                            description: "binary dependencies cannot have a git reference for the version specifier in line: \(scannerWithComments.currentLine)"
                        )
                    )
                    stop = true
                    return
                }

                if dependencies[dependency] == nil {
                    dependencies[dependency] = versionSpecifier
                } else {
                    duplicates.append(dependency)
                }

            case let .failure(error):
                result = .failure(CarthageError(scannableError: error))
                stop = true
                return
            }

            if !scannerWithoutComments.isAtEnd {
                result = .failure(CarthageError.parseError(description: "unexpected trailing characters in line: \(line)"))
                stop = true
            }
        }

        return result.flatMap { _ in
            if !duplicates.isEmpty {
                return .failure(.duplicateDependencies(duplicates.map { DuplicateDependency(dependency: $0, locations: []) }))
            }
            return .success(Cartfile(dependencies: dependencies))
        }
    }
}

extension Cartfile: CustomStringConvertible {
    public var description: String {
        return dependencies
            .sorted { $0.key.description < $1.key.description }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: "\n")
            .appending("\n")
    }
}

/// Returns an array containing dependencies that are listed in both arguments.
public func duplicateDependenciesIn(_ cartfile1: Cartfile, _ cartfile2: Cartfile) -> [Dependency] {
    let projects1 = cartfile1.dependencies.keys
    let projects2 = cartfile2.dependencies.keys
    return Array(Set(projects1).intersection(Set(projects2)))
}

/// Represents a parsed Cartfile.resolved, which specifies which exact version was
/// checked out for each dependency.
public struct ResolvedCartfile {
    /// The dependencies listed in the Cartfile.resolved.
    public let dependencies: [Dependency: PinnedVersion]

    public init(dependencies: [Dependency: PinnedVersion]) {
        self.dependencies = dependencies
    }
}

extension ResolvedCartfile: CartfileProtocol {
    public static var relativePath: String {
        return Constants.Project.resolvedCartfilePath
    }

    /// Attempts to parse Cartfile.resolved information from a string.
    public static func from(string: String) -> Result<ResolvedCartfile, CarthageError> {
        var dependencies = [Dependency: PinnedVersion]()
        var result: Result<(), CarthageError> = .success(())

        let scanner = Scanner(string: string)
        scannerLoop: while !scanner.isAtEnd {
            switch Dependency.from(scanner).fanout(PinnedVersion.from(scanner)) {
            case let .success((dep, version)):
                dependencies[dep] = version

            case let .failure(error):
                result = .failure(CarthageError(scannableError: error))
                break scannerLoop
            }
        }
        return result.map { _ in ResolvedCartfile(dependencies: dependencies) }
    }
}

public struct SchemeCartfile {

    public let schemes: Set<String>

    public init<T: Sequence>(schemes: T) where T.Element == String {
        self.schemes = Set(schemes)
    }

    public var matcher: SchemeMatcher {
        return LitteralSchemeMatcher(schemeNames: schemes)
    }
}

extension SchemeCartfile: CartfileProtocol {

    public static var relativePath: String {
        return Constants.Project.schemesCartfilePath
    }

    public static func from(string: String) -> Result<SchemeCartfile, CarthageError> {
        var schemes = Set<String>()
        let lines = string.components(separatedBy: .newlines)
        for line in lines {
            if line.hasPrefix(Cartfile.commentIndicator) {
                continue
            }
            let scheme = line.trimmingCharacters(in: .whitespaces)

            if !scheme.isEmpty {
                schemes.insert(scheme)
            }
        }
        return .success(SchemeCartfile(schemes: schemes))
    }
}

extension SchemeCartfile: CustomStringConvertible {
    public var description: String {
        return schemes
            .sorted { $0 < $1 }
            .joined(separator: "\n")
            .appending("\n")
    }
}

extension ResolvedCartfile: CustomStringConvertible {
    public var description: String {
        return dependencies
            .sorted { $0.key.description < $1.key.description }
            .map { "\($0.key) \"\($0.value)\"" }
            .joined(separator: "\n")
            .appending("\n")
    }
}

extension String {
    /// Returns self without any potential trailing Cartfile comment. A Cartfile
    /// comment starts with the first `commentIndicator` that is not embedded in any quote
    var strippingTrailingCartfileComment: String {

        // Since the Cartfile syntax doesn't support nested quotes, such as `"version-\"alpha\""`,
        // simply consider any odd-number occurence of a quote as a quote-start, and any
        // even-numbered occurrence of a quote as quote-end.
        // The comment indicator (e.g. `#`) is the start of a comment if it's not nested in quotes.
        // The following code works also for comment indicators that are are more than one character
        // long (e.g. double slashes).

        let quote = "\""

        // Splitting the string by quote will make odd-numbered chunks outside of quotes, and
        // even-numbered chunks inside of quotes.
        // `omittingEmptySubsequences` is needed to maintain this property even in case of empty quotes.
        let quoteDelimitedChunks = self.split(
            separator: quote.first!,
            maxSplits: Int.max,
            omittingEmptySubsequences: false
        )

        for (offset, chunk) in quoteDelimitedChunks.enumerated() {
            let isInQuote = offset % 2 == 1 // even chunks are not in quotes, see comment above
            if isInQuote {
                continue // don't consider comment indicators inside quotes
            }
            if let range = chunk.range(of: Cartfile.commentIndicator) {
                // there is a comment, return everything before its position
                let advancedOffset = (..<offset).relative(to: quoteDelimitedChunks)
                let previousChunks = quoteDelimitedChunks[advancedOffset]
                let chunkBeforeComment = chunk[..<range.lowerBound]
                return (previousChunks + [chunkBeforeComment])
                    .joined(separator: quote) // readd the quotes that were removed in the initial split
            }
        }
        return self
    }
}
