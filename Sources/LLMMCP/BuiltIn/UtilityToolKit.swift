import Foundation
import LLMClient
import LLMTool

// MARK: - UtilityToolKit

/// Four small tools for things a model cannot do on its own: `get_current_time`,
/// `calculate`, `generate_uuid` and `sleep`.
///
/// `get_current_time` is the one that matters most. A model has no clock and will otherwise
/// invent a date, so include this kit whenever the conversation involves "today", "now" or
/// anything relative to them.
///
/// ```swift
/// let tools = ToolSet {
///     UtilityToolKit()
/// }
/// ```
public final class UtilityToolKit: ToolKit, @unchecked Sendable {
    // MARK: - Properties

    public let name: String = "utility"

    private let timeZone: TimeZone

    // MARK: - Initialization

    /// Creates the kit.
    ///
    /// - Parameter timeZone: Zone used when a call does not name one. Defaults to the
    ///   system zone, which on a server is usually UTC rather than the user's.
    public init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    // MARK: - ToolKit Protocol

    public var tools: [any Tool] {
        [
            getCurrentTimeTool,
            calculateTool,
            generateUUIDTool,
            sleepTool
        ]
    }

    // MARK: - Tool Definitions

    /// The `get_current_time` tool: the current time, formatted and in a named zone.
    ///
    /// An unrecognised timezone identifier falls back to the kit's zone without saying so,
    /// though the result echoes the zone actually used. An unrecognised format string is
    /// passed to `DateFormatter`, which produces whatever it makes of it rather than failing.
    private var getCurrentTimeTool: BuiltInTool {
        BuiltInTool(
            name: "get_current_time",
            description: "Get the current time in a specified format and timezone",
            inputSchema: .object(
                properties: [
                    "format": .string(
                        description: "Date format string (e.g., 'yyyy-MM-dd HH:mm:ss', 'ISO8601'). Default is ISO8601."
                    ),
                    "timezone": .string(
                        description: "Timezone identifier (e.g., 'UTC', 'Asia/Tokyo', 'America/New_York'). Default is local timezone."
                    )
                ],
                required: []
            ),
            annotations: ToolAnnotations(
                title: "Get Current Time",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { [timeZone] data in
            let input = try JSONDecoder().decode(GetCurrentTimeInput.self, from: data)

            // An unparseable identifier silently falls back to the kit's zone.
            let tz: TimeZone
            if let tzIdentifier = input.timezone,
               let parsedTZ = TimeZone(identifier: tzIdentifier) {
                tz = parsedTZ
            } else {
                tz = timeZone
            }

            let formatString = input.format ?? "ISO8601"
            let date = Date()

            let formattedDate: String
            if formatString == "ISO8601" {
                let formatter = ISO8601DateFormatter()
                formatter.timeZone = tz
                formattedDate = formatter.string(from: date)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = formatString
                formatter.timeZone = tz
                formattedDate = formatter.string(from: date)
            }

            let result = TimeResult(
                time: formattedDate,
                timezone: tz.identifier,
                format: formatString
            )
            let output = try JSONEncoder().encode(result)
            return .json(output)
        }
    }

    /// The `calculate` tool: one arithmetic operation on `Double` operands.
    ///
    /// Ten named operations, not an expression evaluator, so anything compound takes several
    /// calls. Everything is double-precision, so large integers lose exactness.
    private var calculateTool: BuiltInTool {
        BuiltInTool(
            name: "calculate",
            description: "Perform basic mathematical calculations",
            inputSchema: .object(
                properties: [
                    "operation": .string(
                        description: "Mathematical operation: 'add', 'subtract', 'multiply', 'divide', 'power', 'sqrt', 'abs', 'round', 'floor', 'ceil'"
                    ),
                    "a": .number(description: "First operand (required for all operations)"),
                    "b": .number(description: "Second operand (required for binary operations like add, subtract, multiply, divide, power)")
                ],
                required: ["operation", "a"]
            ),
            annotations: ToolAnnotations(
                title: "Calculate",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { data in
            let input = try JSONDecoder().decode(CalculateInput.self, from: data)

            let result: Double
            switch input.operation.lowercased() {
            case "add", "+":
                guard let b = input.b else {
                    throw UtilityToolKitError.missingOperand(operation: input.operation, operand: "b")
                }
                result = input.a + b

            case "subtract", "-":
                guard let b = input.b else {
                    throw UtilityToolKitError.missingOperand(operation: input.operation, operand: "b")
                }
                result = input.a - b

            case "multiply", "*":
                guard let b = input.b else {
                    throw UtilityToolKitError.missingOperand(operation: input.operation, operand: "b")
                }
                result = input.a * b

            case "divide", "/":
                guard let b = input.b else {
                    throw UtilityToolKitError.missingOperand(operation: input.operation, operand: "b")
                }
                guard b != 0 else {
                    throw UtilityToolKitError.divisionByZero
                }
                result = input.a / b

            case "power", "pow", "^":
                guard let b = input.b else {
                    throw UtilityToolKitError.missingOperand(operation: input.operation, operand: "b")
                }
                result = pow(input.a, b)

            case "sqrt":
                guard input.a >= 0 else {
                    throw UtilityToolKitError.invalidInput(message: "Cannot calculate square root of negative number")
                }
                result = sqrt(input.a)

            case "abs":
                result = abs(input.a)

            case "round":
                result = round(input.a)

            case "floor":
                result = floor(input.a)

            case "ceil":
                result = ceil(input.a)

            default:
                throw UtilityToolKitError.unknownOperation(input.operation)
            }

            let output = CalculateResult(
                operation: input.operation,
                a: input.a,
                b: input.b,
                result: result
            )
            let encoded = try JSONEncoder().encode(output)
            return .json(encoded)
        }
    }

    /// The `generate_uuid` tool: one or more random version-4 UUIDs.
    ///
    /// `count` is clamped to 1...100 rather than rejected. Note that `standard` and
    /// `compact` are lowercased while `uppercase` is not, so `standard` and `uppercase`
    /// differ only in case.
    private var generateUUIDTool: BuiltInTool {
        BuiltInTool(
            name: "generate_uuid",
            description: "Generate a random UUID (Universally Unique Identifier)",
            inputSchema: .object(
                properties: [
                    "format": .string(
                        description: "Output format: 'standard' (with hyphens), 'compact' (no hyphens), 'uppercase'. Default is 'standard'."
                    ),
                    "count": .integer(
                        description: "Number of UUIDs to generate (1-100). Default is 1."
                    )
                ],
                required: []
            ),
            annotations: ToolAnnotations(
                title: "Generate UUID",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { data in
            let input = try JSONDecoder().decode(GenerateUUIDInput.self, from: data)

            let format = input.format ?? "standard"
            let count = min(max(input.count ?? 1, 1), 100)

            let uuids: [String] = (0..<count).map { _ in
                let uuid = UUID()
                switch format.lowercased() {
                case "compact":
                    return uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                case "uppercase":
                    return uuid.uuidString
                default:  // standard
                    return uuid.uuidString.lowercased()
                }
            }

            let result = GenerateUUIDResult(uuids: uuids, format: format, count: count)
            let output = try JSONEncoder().encode(result)
            return .json(output)
        }
    }

    /// The `sleep` tool: pause before continuing, for polling and for backing off.
    ///
    /// The duration is clamped to 0.001...60 seconds rather than rejected, and the result
    /// reports both what was asked for and what was actually waited. Cancellation propagates,
    /// so a cancelled agent run does not have to wait this out.
    private var sleepTool: BuiltInTool {
        BuiltInTool(
            name: "sleep",
            description: "Wait for a specified duration",
            inputSchema: .object(
                properties: [
                    "seconds": .number(
                        description: "Duration to wait in seconds (0.001 - 60)"
                    )
                ],
                required: ["seconds"]
            ),
            annotations: ToolAnnotations(
                title: "Sleep",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { data in
            let input = try JSONDecoder().decode(SleepInput.self, from: data)

            // Clamp rather than reject: a model asking for an hour gets a minute.
            let duration = min(max(input.seconds, 0.001), 60.0)
            let nanoseconds = UInt64(duration * 1_000_000_000)

            try await Task.sleep(nanoseconds: nanoseconds)

            let result = SleepResult(requestedSeconds: input.seconds, actualSeconds: duration)
            let output = try JSONEncoder().encode(result)
            return .json(output)
        }
    }
}

// MARK: - Input Types

private struct GetCurrentTimeInput: Codable {
    var format: String?
    var timezone: String?
}

private struct CalculateInput: Codable {
    var operation: String
    var a: Double
    var b: Double?
}

private struct GenerateUUIDInput: Codable {
    var format: String?
    var count: Int?
}

private struct SleepInput: Codable {
    var seconds: Double
}

// MARK: - Result Types

private struct TimeResult: Codable {
    var time: String
    var timezone: String
    var format: String
}

private struct CalculateResult: Codable {
    var operation: String
    var a: Double
    var b: Double?
    var result: Double
}

private struct GenerateUUIDResult: Codable {
    var uuids: [String]
    var format: String
    var count: Int
}

private struct SleepResult: Codable {
    var requestedSeconds: Double
    var actualSeconds: Double
}

// MARK: - Errors

/// Failures from ``UtilityToolKit``.
public enum UtilityToolKitError: Error, LocalizedError {
    case missingOperand(operation: String, operand: String)
    case divisionByZero
    case invalidInput(message: String)
    case unknownOperation(String)

    public var errorDescription: String? {
        switch self {
        case .missingOperand(let operation, let operand):
            return "Operation '\(operation)' requires operand '\(operand)'"
        case .divisionByZero:
            return "Division by zero is not allowed"
        case .invalidInput(let message):
            return message
        case .unknownOperation(let operation):
            return "Unknown operation: \(operation)"
        }
    }
}
